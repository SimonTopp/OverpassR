#All packages used at some point in the project - will narrow down at the end
library(shiny)
library(leaflet)
library(sf)
library(tidyverse)
library(RColorBrewer)
library(sp)
library(rgdal)
library(lubridate)
library(DT)
library(dplyr)
library(plyr)

#Read the wrs tiles 
wrs <- st_read('data/in/wrs2_asc_desc.shp')
wrs <- wrs[wrs$MODE == 'D',]

#Lookup table and array of dates
lookup_table <- read.delim('data/in/lookup_table.txt')

#Global variable output table. It will update with each map click and reset only when 'reset map' button is clicked
global_table = data.frame()


ui <- fluidPage(
  
  fixedRow(
    column(4, offset = 5,
           titlePanel("OverpassR"))
  ),
  
  fixedRow(
    column(10, offset = 3, 
           mainPanel("Click on map or enter coordinates to view satellite overpass information")
    )
  ),
  
  leafletOutput('map', width = 1000, height = 500),
  
  fluidRow(
    column(1, offset = 0, actionButton("refreshButton", "Reset")),
    uiOutput("ui")
  ),
  
  #Row with coordinate input, date input, search
  fixedRow(
    
    column(2, offset = 1,
           textInput("lat", label = NULL , value = "", placeholder = "Lat", width = 130)
    ),
    column(2,
           textInput("lon", label = NULL , value = "", placeholder = "Lon", width = 130)
    ),
    
    column(1, offset = 0, 
           actionButton("find", label = "Find")
    ),
    
    column(3, offset = 2,
           dateRangeInput("dates", "Date range:",
                          start = Sys.Date(),
                          end = Sys.Date()+16)
    )
  ),
  
  #Apply Date Button
  fixedRow( 
    column(1, offset = 8,
           actionButton('applyDates', "Apply Date Filter")
    )
  ),
  
  fluidRow(
    DTOutput('table')
  ),
  
  fixedRow(
    mainPanel(" ")
  ),
  
  fixedRow(
    column(1, offset = 8, 
           downloadButton('download', "Download") )
  )
)



server <- function(input, output, session){
  
  proxy_table = dataTableProxy('table')
  proxyMap <- leafletProxy("map")
  
  
  #Render map with base layers WorldImagery and Labels
  output$map <- renderLeaflet({
    
    leaflet() %>%
      addTiles(group = "Default") %>%
      addProviderTiles(providers$Esri.WorldImagery, group = "Satellite") %>%
      addProviderTiles(providers$CartoDB.VoyagerOnlyLabels, group = "Satellite") %>%
      setView(lat=10, lng=0, zoom=2)  %>%
      addLayersControl(
        baseGroups = c("Default", "Satellite"),
        options = layersControlOptions(collapsed = FALSE)
      )
  })
  
  
  observeEvent(input$find,{
    
    lon <- input$lon %>% as.numeric()
    lat <- input$lat %>% as.numeric()
    validate(
      need((validCoords(lon, lat)), "Enter valid coordinates")
    )
    
    generate(lon, lat)
  })
  
  
  observeEvent(input$map_click,{
    
    if(is.null(input$map_click))
      return() 
    
    #clean up
    click <- input$map_click
    lon <- click$lng
    lat <- click$lat
    
    generate(lon, lat)
    
  })
  
  
  #Use a separate observer to clear shapes and output table if "clear tiles" button clicked
  observeEvent(input$refreshButton,{
    
    if(is.null(input$refreshButton))
      return()
    
    proxyMap%>% clearShapes()
    
    updateDateRangeInput(session, "dates", "Date range:",
                         start = Sys.Date(), end = Sys.Date()+16)
    
    output$table <- renderDT(NULL)
    global_table <<- NULL
    
  }
  )
  
  #Updates map with tiles and global table with data given coordinates of a click
  generate <- function(lon, lat){
    
    df <- returnPR(lon, lat, wrs)
    paths <- df$path
    rows <- df$row
    tile_shapes <- df$shape.geometry
    
    #Shape file of tiles that intersect
    reference_date <- lookup_table[paths,]$Overpass
    
    #Handles if date filter is applied  
    if(input$applyDates){
      
      
      validate(
        need( (as.numeric(input$dates[2] - input$dates[1]) >=16), message =  "Please enter valid date range") 
      )
      
      start_date <- input$dates[1]
      end_date <- input$dates[2]
      
      days_til <- (as.numeric(start_date - reference_date)) %% 16
      next_pass <- (start_date + days_til) %>% as.Date()
      
      len <- 1:length(next_pass)
      updating_table <- NULL
      
      #Each loop iteration creates a data frame "temp" of dates, path, row, lat, lon for one tile
      ## Subseqeuent iterations create a temp data frame, then append the new data frame to the previous one
      for (r in len){
        dates <- seq.Date(next_pass[r], to = end_date, by = 16) %>% as.character()
        temp <- cbind("Date" = dates, "Path" = paths, "Row" = rows, "Lat" = lat, "Long" = lon)
        updating_table <- rbind(updating_table, temp)
      }
      
      
    }
    
    #No date filter
    else{
      
      
      days_til <- (as.numeric(Sys.Date()) - reference_date) %% 16
      next_pass <- (Sys.Date() + days_til) %>% as.character.Date()
      
      #Table with all of the data from the map click
      updating_table <-  cbind("Date" = next_pass, "Path" = paths, 
                               "Row" = rows, "Lat" = lat, "Long" = lon) %>% as.data.frame()
      
      #Fixes a bug that would give manually entered coordinates with no tile 
      #a place on the output table, throwing a rbind error
      if(is.null(updating_table$Date))
        return()
      
    }
    
    #Renders distinct output
    if(!is.null(global_table)){
      global_table <<- rbind(updating_table, global_table)
      x <- duplicated(global_table[,1:3])
      global_table <<- global_table[!x,]
    }
    
    else
      global_table <<- updating_table
    
    #Display table
    output$table <<- renderDT(
      global_table, options = list(paging = FALSE, searching = FALSE, info = FALSE) 
    )
    
    #Update the map: clear all tiles, then add only the ones that overlap in Red
    leafletProxy("map") %>%
      addTiles(group = "Default") %>%
      addProviderTiles(providers$Esri.WorldImagery, group = "Satellite") %>%
      addProviderTiles(providers$CartoDB.VoyagerOnlyLabels, group = "Satellite") %>%
      setView(lng = lon , lat = lat, zoom = 6) %>%
      addPolygons(
        data = tile_shapes, color = 'blue', weight = 1, 
        highlightOptions = highlightOptions(color = 'black', weight = 3, bringToFront = TRUE), 
        label = row_number(global_table$Path)) %>%
      addLayersControl(
        baseGroups = c("Default", "Satellite"),
        options = layersControlOptions(collapsed = TRUE))
  }
  
  output$download <- downloadHandler(
    filename = "overpassR.csv",
    content = function(file){
      write.csv(global_table, file, row.names = TRUE)
    }
  )
}


#Helper methods---------------------------------------------------------------------------------------------------


#Helper method takes lon, lat, shapefile, and returns PR of intersected tiles 
returnPR <- function(lon, lat, shapefile){
  
  #Validate input.
  #PROBLEM: Why is shiny not rendering this output message? 
  validate(
    need(validCoords(lon, lat), "Enter valid coordinates")
  )
  
  coords <- as.data.frame(cbind(lon, lat)) 
  point <- SpatialPoints(coords)
  proj4string(point) <- CRS("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")
  
  #Convert the point to a shape file so they can intersect
  pnt <-  st_as_sf(point, coords = c('lon' , 'lat'))
  
  #Create a boolean matrix of all the polygons that intersect pnt (a user's mapclick)
  ## And select those polygons from WRS
  bool_selector <- st_intersects(shapefile, pnt, sparse = FALSE)
  tiles <- (shapefile[bool_selector,])
  paths <-  tiles$PATH
  rows <- tiles$ROW
  
  return(data.frame("path" = paths, "row" = rows, "shape" = tiles))
  
}


validCoords <- function(lon, lat){
  
  if(is.null(lon) | is.null(lat)
     | is.na(lon) | is.na(lat))
    return(FALSE)
  
  return(
    (lat>=-90 && lat<=90) && 
      (lon>=-180 && lon<=180)
  )
  
} 


shinyApp(ui, server)