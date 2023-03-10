let
    Source = try Inventory catch (e) => error e,
    #"Removed Other Columns" = Table.SelectColumns(
        Source,
        {
            "Asset Name",
            "Classification",
            "Section",
            "Year Installed",
            "DCR",
            "# of Active Work Items",
            "Size/QTY",
            "Units",
            "Inventoried Date",
            "Primary Photo Count",
            "Photo Count",
            "Comments",
            "Rating Notes",
            "Inventoried By"
        }
    ),
    #"Split Column by Delimiter" = Table.SplitColumn(
        #"Removed Other Columns",
        "Classification",
        Splitter.SplitTextByEachDelimiter({"-"}, QuoteStyle.Csv, false),
        {"Classification.1", "Classification.2"}
    ),
    #"Changed Type" = Table.TransformColumnTypes(
        #"Split Column by Delimiter", {{"Classification.1", type text}, {"Classification.2", type text}}
    ),
    #"Renamed Columns" = Table.RenameColumns(
        #"Changed Type", {{"Classification.1", "Classification.ID"}, {"Classification.2", "Classification.Desc"}}
    ),
    #"Extracted Text Before Delimiter" = Table.TransformColumns(
        #"Renamed Columns", {{"Classification.ID", each Text.BeforeDelimiter(_, " "), type text}}
    ),
    baseTable = Table.TransformColumns(
        #"Extracted Text Before Delimiter", {{"Classification.Desc", each Text.AfterDelimiter(_, " "), type text}}
    ),
    invDate = try List.Mode(baseTable[Inventoried Date]) otherwise #date(1900, 1, 1),
    //********************************************** Setup *********************************************************************************************
    mq1 = Table.NestedJoin(
        baseTable, {"Asset Name"}, ParagonAssetData, {"Asset Name"}, "ParagonAssetData", JoinKind.LeftOuter
    ),
    mrgBaseAsset1 = Table.ExpandTableColumn(
        mq1,
        "ParagonAssetData",
        {"Year Built", "Asset Size", "Location Type", "FAC Code"},
        {"Year Built", "Asset Size", "Asset.LocationType", "FAC Code"}
    ),
    mrgBaseAsset = Table.SelectRows(mrgBaseAsset1, (r) => r[Asset.LocationType] = 1200),
    //********************************************** Setup *********************************************************************************************
    // Missing Item Function
    HandleMissingItems = (tbl as table, classLst as list, note as text) as table =>
        let
            badGrp = Table.Group(
                tbl,
                {"Asset Name", "Year Built", "Asset Size"},
                {"Found", (t) => Table.MatchesAnyRows(t, (r) => List.Contains(classLst, r[Classification.ID]))}
            ),
            tct = Table.TransformColumnTypes(badGrp, {{"Found", type logical}}),
            badFlt = Table.SelectRows(tct, (r) => not r[Found]),
            badRemCol = Table.RemoveColumns(badFlt, {"Found"}),
            missingItemT = Table.AddColumn(badRemCol, "Notes", (r) => note & " not found.")
        in
            missingItemT,
    //**********************************************Checks**********************************************************************
    //Check for placeholder
    placeHolder_Qty = Table.SelectRows(
        baseTable,
        (r) =>
            List.MatchesAny(
                {
                    99999,
                    9999,
                    999,
                    88888,
                    8888,
                    888,
                    77777,
                    7777,
                    777,
                    66666,
                    6666,
                    666,
                    55555,
                    5555,
                    555,
                    11111,
                    1111,
                    111,
                    0
                },
                (i) => i = r[#"Size/QTY"]
            )
    ),
    //Add warning column
    placeHolder_Warning = Table.AddColumn(
        placeHolder_Qty, "Notes", (r) => "Likely placeholder value used for Size/Qty."
    ),
    //Create a table with warnings
    warningTable = Table.SelectColumns(
        placeHolder_Warning, {"Asset Name", "Classification.ID", "Size/QTY", "Inventoried By", "Notes"}
    ),

    // Check for duplicates
    ruleDate = #date(2022, 10, 20),
    dupLst = Table.Group(
        baseTable,
        {"Asset Name", "Classification.ID", "Year Installed", "Section"},
        {
            {"Count", (tbl) => List.Count(tbl[Classification.ID])},
            {
                "Inventoried By",
                (tbl) =>
                    Text.BeforeDelimiter(
                        Lines.ToText(List.Distinct(tbl[Inventoried By]), " / "), " / ", {0, RelativePosition.FromEnd}
                    )
            }
        }
    ),
    dupLst1 = Table.SelectRows(dupLst, (r) => r[Count] > 1),
    dupLst2 = Table.AddColumn(dupLst1, "Notes", (r) => "Possible duplicate inventory item."),
    dupLstT = if (invDate ?? #date(1900, 1, 1)) > ruleDate then dupLst2 else null,
    //***********************************************SITE START******************************************************************
    //IDEA: Check "fuzzy language" in asset summary for missing components, Can also check if site is tribally owned for one case
    //Missing Site Water Pipe
    classListSWP = {
        "G301002001",
        "G301002002",
        "G301002003",
        "G301002004",
        "G301002005",
        "G301002006",
        "G301002008",
        "G301002009",
        "G301002010",
        "G301002011",
        "G301002012",
        "G301002013",
        "G301002014",
        "G301002015",
        "G301002016"
    },
    badSWP = HandleMissingItems(mrgBaseAsset, classListSWP, "Domestic Water Pipe"),
    //Missing Sanitary Sewer Pipe
    classListSSP = {
        "G302001001",
        "G302001002",
        "G302001003",
        "G302001004",
        "G302001005",
        "G302001006",
        "G302001008",
        "G302001009",
        "G302001010",
        "G302001011",
        "G302001012",
        "G302001013",
        "G302001014",
        "G302001015"
    },
    badSSP = HandleMissingItems(mrgBaseAsset, classListSSP, "Sanitary Sewer Pipe"),
    //Missing Sidewalk
    classListCS = {"G203003004", "G203003006"},
    badCS = HandleMissingItems(mrgBaseAsset, classListCS, "Concrete Sidewalk"),
    //Missing Concrete Curb
    classListCC = {"G201002001", "G201002002", "G202002001", "G202002002", "G203002001", "G203002002"},
    badCC = HandleMissingItems(mrgBaseAsset, classListCC, "Concrete Curb"),
    //Missing Gates
    classListFences = {
        "G204001001",
        "G204001002",
        "G204001003",
        "G204001004",
        "G204001005",
        "G204001006",
        "G204001007",
        "G204001009",
        "G204001010",
        "G204001100",
        "G204001200",
        "G204001200",
        "G204001300"
    },
    badFence = HandleMissingItems(mrgBaseAsset, classListFences, "Fencing"),
    //Missing Chain link fencing
    classListGates = {"G204001006", "G204001007", "G204001009", "G204001210"},
    badGates = HandleMissingItems(mrgBaseAsset, classListGates, "Gates"),
    //Missing Parking Lot (includes gravel lot)
    classListPL = {"G202003100", "G202001002"},
    badPL = HandleMissingItems(mrgBaseAsset, classListPL, "Parking Lot"),
    //Missing Roadway
    classListRW = {"G201003100", "G201003006", "G201003004"},
    badRW = HandleMissingItems(mrgBaseAsset, classListRW, "Roadway"),
    //Missing Light Pole
    classListLP = {
        "G402006001",
        "G402006002",
        "G402006003",
        "G402006004",
        "G402006005",
        "G402006006",
        "G402006007",
        "G402006008",
        "G402006009",
        "G402006010",
        "G402006011",
        "G402006012",
        "G402006013",
        "G402006014",
        "G402006015",
        "G402006016",
        "G402006017",
        "G402006018",
        "G402006019",
        "G402006020",
        "G402006021",
        "G402006022",
        "G402006023",
        "G402006024",
        "G402006025",
        "G402006026",
        "G402006027",
        "G402006028",
        "G402006029",
        "G402006030"
    },
    badLP = HandleMissingItems(mrgBaseAsset, classListLP, "Light Pole"),
    //Missing Light Fixture
    classListLF = {
        "G402006031",
        "G402006032",
        "G402006033",
        "G402006034",
        "G402006035",
        "G402006036",
        "G402006037",
        "G402006038",
        "G402006039",
        "G402006040"
    },
    badLF = HandleMissingItems(mrgBaseAsset, classListLF, "Light Fixture"),
    //***********************************************SITE END******************************************************************
    // Merge all validation tables.
    lst = List.RemoveNulls({badSWP, badSSP, badCS, badCC, badFence, badGates, badPL, badRW, badLP, badLF}),
    output = Table.Sort(Table.Combine(lst), {"Asset Name", "Notes"})
in
    output
