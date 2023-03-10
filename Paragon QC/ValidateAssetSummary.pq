let
    Source = Excel.CurrentWorkbook(){[Name="AssetsMissingInventory"]}[Content],
    //Selects columns we need
    #"Remove Other Columns" = Table.SelectColumns(Source,{"Asset Summary", "Asset History", "Locatio Type", "Site ID"}),
    //Error handling to remove any empty or errored cells
    #
    //Replace null or empty values
    #"Changed Type" = Table.TransformColumnTypes(Source,{{"Asset Name", type text}, {"Property Record ID", type text}, {"IA Status", type text}, {"Portable (Y/N)", type text}, {"Possible Issue", type text}, {"Class.A", Int64.Type}, {"Class.B", Int64.Type}, {"Class.C", Int64.Type}, {"Class.D", Int64.Type}, {"Class.E", Int64.Type}, {"Class.F", Int64.Type}, {"Class.G", Int64.Type}})
in
    #"Changed Type"




    //NOTE: I need to potentially filter only Location Type. This may not be the case becuase all assets have summaries.