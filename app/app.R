library(shiny)
options(shiny.sanitize.errors = FALSE)
library(ibmdbR)  
library(dplyr)
library(tidyr)
library(forcats)
library(ggplot2)
library(ggmap)
library(leaflet)
library(DT)
library(sp)
library(rgdal)
library(jsonlite)
library(httr)

SCORING_HREF = ""
auth_header = c("")
names(auth_header)[1] = "Authorization"

dsn_driver <- "DASHDB"  
dsn_database <- "BLUDB"
dsn_hostname <- ""
dsn_port <- "50000"  
dsn_protocol <- "TCPIP"  
dsn_uid <- ""
dsn_pwd <- ""

conn_path <- paste(dsn_driver,  
                   ";DATABASE=",dsn_database,
                   ";HOSTNAME=",dsn_hostname,
                   ";PORT=",dsn_port,
                   ";PROTOCOL=",dsn_protocol,
                   ";UID=",dsn_uid,
                   ";PWD=",dsn_pwd,sep="")

# connect to db -----------------------------------------------------------

odbcCloseAll()
ch <- idaConnect(conn_path)
idaInit(ch)

bikepoints = ida.data.frame("DASH14210.BIKEPOINTS")
bikepoints <- as.data.frame(bikepoints)
bikepoints$distance <- 0
bikepoints$withinMaxRadius <- FALSE

# functions to convert between lat / lon and eastings / northings
wgs84 = "+init=epsg:4326"
bng = '+proj=tmerc +lat_0=49 +lon_0=-2 +k=0.9996012717 +x_0=400000 +y_0=-100000 
+ellps=airy +datum=OSGB36 +units=m +no_defs'

ConvertCoordinatesEN <- function(easting,northing) {
  out = cbind(easting,northing)
  mask = !is.na(easting)
  sp <-  sp::spTransform(sp::SpatialPoints(list(easting[mask],northing[mask]),proj4string=sp::CRS(bng)),sp::CRS(wgs84))
  out[mask,]=sp@coords
  colnames(out) <- c("lon", "lat")
  out
}

ConvertCoordinatesLL <- function(lat,lon) {
  out = cbind(lat,lon)
  mask = !is.na(lat)
  sp <- sp::spTransform(sp::SpatialPoints(list(lon[mask], lat[mask]), proj4string=sp::CRS("+proj=longlat")),sp::CRS(bng))
  out[mask,]=sp@coords
  colnames(out) <- c("easting", "northing")
  out
}

# function to find geolocation of postcode
getGeoLoc <- function(postcode) {
  searchLatLong <- geocode(postcode, output = "more")
  searchEN <- ConvertCoordinatesLL(lat = searchLatLong["lat"], lon = searchLatLong["lon"])
  return(list(lon = searchLatLong[["lon"]], 
              lat = searchLatLong[["lat"]], 
              easting = searchEN[["easting"]], 
              northing = searchEN[["northing"]]))
}

# function to alter the bikepoints dataset with a 'within max range' col
withinMaxRadius <- function(postcode, maxRadius) {
  pcGeoLoc <- getGeoLoc(postcode = postcode)
  bikepoints.distance <- sqrt(
    (bikepoints$EASTING - pcGeoLoc[["easting"]])^2 + 
    (bikepoints$NORTHING - pcGeoLoc[["northing"]])^2)
  bikepoints.withinMaxRadius <- bikepoints.distance < maxRadius
  return(list(distance = bikepoints.distance,
              withinMaxRadius = bikepoints.withinMaxRadius))
}

getScore <- function(withinMaxRadius,
                     POLLED_TIME_AMPK,
                     POLLED_TIME_PMPK,
                     POLLED_TIME_WEEKDAY,
                     CHX_DIST,
                     SPACES) {
  
  if (withinMaxRadius==TRUE) {
    predictors <- list(record = c(POLLED_TIME_AMPK, POLLED_TIME_PMPK, POLLED_TIME_WEEKDAY, SPACES, CHX_DIST))
    req.body <- toJSON(predictors)
    #res <- PUT(url = SCORING_HREF,body = req.body,headers=HEADER_ONLINE, add_headers(.headers = auth_header), content_type_json())
    res <- PUT(url = SCORING_HREF,body = req.body, add_headers(.headers = auth_header), content_type_json())
    if (CHX_DIST > 3411.5 & CHX_DIST < 3411.6) {response <<- res}
    if (res$status_code == 200) {
      spaces.prob <- content(res)$result$probability$values[[1]]
    } else {
      spaces.prob <- NA
    }
    
    return(spaces.prob)
  } else {
    return(NA)
  }
}

runScores <- function() {
  # read in latest data from ODS
  latest <<- ida.data.frame("DASH14210.BIKEPOINT_ODS")  
  latest <<- as.data.frame(latest)
  
  # score against postcode
  withinMaxTest <- withinMaxRadius(postcode, maxRadius)
  bikepoints$distance <<- withinMaxTest[["distance"]]
  bikepoints$withinMaxRadius <<- withinMaxTest[["withinMaxRadius"]]
  
  bikepoints_joined <- bikepoints %>%
    select(-LAT,
           -LON) %>% 
    inner_join(latest, by = "ID")
  
  bikepoints_scored <<- bikepoints_joined %>% 
    rowwise() %>% 
    mutate(score = getScore(withinMaxRadius,
                            POLLED_TIME_AMPK,
                            POLLED_TIME_PMPK,
                            POLLED_TIME_WEEKDAY,
                            CHX_DIST,
                            SPACES))
  
  return(bikepoints_scored)
}

# startup parameters
postcode <- "se1 9pz"
maxRadius <- 500
runScores()

getColour <- function(scores) {
  sapply(scores$score, function(score) {
    if(score <= 0.5) {
      "red"
    } else if(score <= 0.8) {
      "orange"
    } else {
      "green"
    } })
}



ui <- fluidPage(
  titlePanel("BikePoint predictive modelling",
             "BikePoint predictive modelling"),
  sidebarLayout(
    sidebarPanel(
      tags$div(class="header", checked=NA,
              tags$p("Enter a London postcode below and hit search to see our latest prediction of whether there will be a hire bike parking space nearby in 30 minutes time.")),
               
      textInput("postcode", "postcode", value = ""),
      sliderInput("radius", "maximum search radius (m)", min=100, max=1000,value=500,step=100),
      actionButton("searchButton", "Search"),
      plotOutput("trend")
    ),
    mainPanel(
      leafletOutput("mymap"),
      dataTableOutput("stations")
    )
  )
)

server <- function(input, output) {
  
  nearestStations <- eventReactive(input$searchButton, {
    postcode <<- input$postcode
    maxRadius <<- input$radius
    scoring_output <- runScores()
    scoring_output %>%
      filter(withinMaxRadius == TRUE) %>% 
      select(ID, 
             BOROUGH, 
             LAT, 
             LON, 
             distance, 
             DOCKS, 
             BIKES, 
             SPACES,
             SPACES_LAG1,
             SPACES_LAG2, 
             SPACES_LAG3, 
             score) %>% 
      mutate(distance = round(distance, 0),
             score = round(score, 3)) %>% 
      arrange(distance)
  })
  
  output$mymap <- renderLeaflet({
    icons <- awesomeIcons(
      icon = 'ios-close',
      iconColor = 'black',
      library = 'ion',
      markerColor = getColour(nearestStations())
    )
    
    leaflet(data = nearestStations()) %>%
      addProviderTiles(providers$OpenStreetMap,
                       options = providerTileOptions(noWrap = TRUE)) %>% 
      addAwesomeMarkers(lat = ~LAT, 
                 lng = ~LON,
                 popup = ~ID,
                 label = ~ID,
                 icon = icons)
  })
  
  output$stations <- renderDataTable({nearestStations() %>% 
      select(id = ID, 
             borough = BOROUGH, 
             distance, 
             docks = DOCKS,
             bikes = BIKES,
             spaces = SPACES,
             score)},
    selection = "multiple",
    options=list(
        paging = FALSE,
        searching = FALSE)
  )
  
  output$trend <- renderPlot({
    chartStations <- nearestStations() %>% 
      select(ID,
             `0 mins` = SPACES,
             `-10 mins` = SPACES_LAG1,
             `-20 mins` = SPACES_LAG2,
             `-30 mins` = SPACES_LAG3) %>% 
      gather(key = "Offset",
             value = "Spaces",
             -ID) %>% 
      mutate(Offset = factor(Offset),
             Offset = factor(Offset, levels = levels(Offset)[c(4,1,2,3)]))
    
    s <- input$stations_rows_selected
    if (length(s) > 0) { 
      selected_ids <- as.vector(nearestStations()[s,]$ID)
      chartStations <- chartStations %>% 
        filter(ID %in% selected_ids)
      }
    
    chartStations %>%   
      ggplot(aes(x=Offset,
                 y=Spaces,
                 colour=ID,
                 group=ID)) +
      geom_line() +
      theme(legend.position="bottom")
  })
  
}

shinyApp(ui, server)


