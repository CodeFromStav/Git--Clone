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
    //********************************************** Global **************************************************************************************************************
    // Check for placeholder size numbers
    phSize1 = Table.SelectRows(
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
    phSize2 = Table.AddColumn(phSize1, "Notes", (r) => "Likely placeholder value used for Size/Qty."),
    badPHSizeT = Table.SelectColumns(
        phSize2, {"Asset Name", "Classification.ID", "Size/QTY", "Inventoried By", "Notes"}
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
    //********************************************** Global **************************************************************************************************************
    // Setup
    mq1 = Table.NestedJoin(
        baseTable, {"Asset Name"}, ParagonAssetData, {"Asset Name"}, "ParagonAssetData", JoinKind.LeftOuter
    ),
    mrgBaseAsset1 = Table.ExpandTableColumn(
        mq1,
        "ParagonAssetData",
        {"Year Built", "Asset Size", "Location Type", "FAC Code"},
        {"Year Built", "Asset Size", "Asset.LocationType", "FAC Code"}
    ),
    mrgBaseAsset = Table.SelectRows(mrgBaseAsset1, (r) => r[Asset.LocationType] = 1100),
    // Missing Item Function
    HandleMissingItems = (masterTbl as table, ignoreFACLst as list, classLst as list, warn as text) as table =>
        let
            // Get the most occuring Prefix letter for the class
            classGroupPrefix = List.Mode(List.Transform(classLst, (li) => Text.At(li, 0))),
            badGrp = Table.Group(
                masterTbl,
                {"Asset Name", "Year Built", "Asset Size", "FAC Code"},
                {
                    {"Found", (t) => Table.MatchesAnyRows(t, (r) => List.Contains(classLst, r[Classification.ID]))},
                    {
                        "Inventoried By",
                        (t) =>
                            Table.First(
                                Table.SelectRows(t, (r) => Text.StartsWith(r[Classification.ID], classGroupPrefix)),
                                [Inventoried By = ""]
                            )[Inventoried By]
                    }
                }
            ),
            tct = Table.TransformColumnTypes(badGrp, {{"Found", type logical}}),
            badFlt = Table.SelectRows(tct, (r) => not r[Found] and not List.Contains(ignoreFACLst, r[FAC Code])),
            badRemCol = Table.RemoveColumns(badFlt, {"Found"}),
            missingItemT = Table.AddColumn(badRemCol, "Notes", (r) => warn & " not found.")
        in
            missingItemT,
    //********************************************** Structure **************************************************************************************************************
    // Find if GSF compares to structure SF
    grpSlab = Table.Group(
        mrgBaseAsset,
        {"Asset Name", "Asset Size"},
        {
            {
                "Size/QTY",
                (tbl) =>
                    List.Sum(
                        Table.SelectRows(
                            tbl, (r) => List.MatchesAny(FootprintCodes, (fpc) => fpc = r[Classification.ID])
                        )[#"Size/QTY"]
                    )
            },
            {
                "Classification.ID",
                (tbl) =>
                    Text.BeforeDelimiter(
                        Lines.ToText(
                            Table.SelectRows(
                                tbl, (r) => List.MatchesAny(FootprintCodes, (fpc) => fpc = r[Classification.ID])
                            )[Classification.ID],
                            "#(cr)#(lf)"
                        ),
                        "#(cr)#(lf)",
                        {0, RelativePosition.FromEnd}
                    )
            },
            {
                "Inventoried By",
                (tbl) =>
                    Text.BeforeDelimiter(
                        Lines.ToText(
                            List.Distinct(
                                Table.SelectRows(
                                    tbl, (r) => List.MatchesAny(FootprintCodes, (fpc) => fpc = r[Classification.ID])
                                )[Inventoried By]
                            ),
                            " / "
                        ),
                        " / ",
                        {0, RelativePosition.FromEnd}
                    )
            }
        }
    ),
    grpSlab1 = Table.SelectRows(grpSlab, (r) => r[#"Size/QTY"] <> null and r[Asset Size] <> r[#"Size/QTY"]),
    grpSlabT = Table.AddColumn(grpSlab1, "Notes", (r) => "Slab/Deck Total does not match Asset Size."),
    // Missing Roof Insulation
    ignoreFACRI = {353004, 354104, 354105, 358000, 358015, 355002},
    badRIT = HandleMissingItems(mrgBaseAsset, ignoreFACRI, {"B301003001", "B301003002"}, "Roof Insulation"),
    /*
    // Validate footprint has proper Section 1FL
    bad1FL1 = Table.SelectRows(baseTable, (r) => List.Contains(FootprintCodes, r[Classification.ID])),
    bad1FLGrp = Table.Group(bad1FL1, {"Asset Name"}, {"1FL Found", (t) => Table.MatchesAnyRows(t, (r) => r[Section] = "1FL")} ),
    #"Changed Type1" = Table.TransformColumnTypes(bad1FLGrp,{{"1FL Found", type logical}}),
    bad1FLFlt = Table.SelectRows(#"Changed Type1", (r) => not r[1FL Found]),
    bad1FLRemCol = Table.RemoveColumns(bad1FLFlt, {"1FL Found"}),
    bad1FLIB = Table.AddColumn(bad1FLRemCol, "Inventoried By", (r) => "Structure/Lead"),
    bad1FLT = Table.AddColumn(bad1FLIB, "Notes", (r) => "Inventory missing 1FL in at least 1 Section for footprint."),
 */
    //********************************************** Structure **************************************************************************************************************
    //********************************************** MEP **************************************************************************************************************
    // Size does not match Asset GSF
    sizeChkLst = {
        [
            ID = "D503004001",
            Warn = "Public Address System"
        ],
        [
            ID = "D503008010",
            Warn = "CCTV System"
        ],
        [
            ID = "D503001001",
            Warn = "Fire Alarm System"
        ],
        [
            ID = "D502001001",
            Warn = "Branch Wiring"
        ],
        [
            ID = "D401001001",
            Warn = "Wet Pipe Sprinkler System"
        ],
        [
            ID = "D401001002",
            Warn = "Dry Pipe Sprinkler System"
        ],
        [
            ID = "D503005012",
            Warn = "Data and Voice System"
        ]
    },
    chkSizeT = Table.SelectRows(
        mrgBaseAsset, (r) => List.MatchesAny(sizeChkLst, (li) => r[Classification.ID] = li[ID])
    ),
    grpSizeT = List.Accumulate(
        sizeChkLst,
        null,
        (state, curr) =>
            Table.Combine(
                List.RemoveNulls(
                    {
                        state,
                        Table.Group(
                            chkSizeT,
                            {"Asset Name", "Asset Size", "Classification.ID"},
                            {
                                {
                                    "Size/QTY",
                                    (t) =>
                                        List.Sum(
                                            Table.SelectRows(t, (r) => r[Classification.ID] = curr[ID])[#"Size/QTY"]
                                        )
                                },
                                {
                                    "Inventoried By",
                                    (tbl) =>
                                        Text.BeforeDelimiter(
                                            Lines.ToText(List.Distinct(tbl[Inventoried By]), " / "),
                                            " / ",
                                            {0, RelativePosition.FromEnd}
                                        )
                                }
                            }
                        )
                    }
                )
            )
    ),
    fltSizeT = Table.SelectRows(grpSizeT, (r) => (r[#"Size/QTY"] <> null) and (r[Asset Size] <> r[#"Size/QTY"])),
    badSizeT = Table.AddColumn(
        fltSizeT,
        "Notes",
        (r) =>
            Text.Format(
                "#[Warn] size does not match Asset size.",
                List.First(List.Select(sizeChkLst, (li) => r[Classification.ID] = li[ID]))
            )
    ),
    // Missing Branch Wiring
    ignoreFACBW = {
        353003,
        401204,
        401202,
        408004,
        401302,
        401609,
        358001,
        404002,
        404003,
        404004,
        404005,
        201001,
        407702,
        407504,
        358000,
        354105
    },
    badWireT = HandleMissingItems(mrgBaseAsset, ignoreFACBW, {"D502001001"}, "Branch Wiring"),
    // Missing Electric Panel
    badEPT = HandleMissingItems(
        mrgBaseAsset,
        ignoreFACBW,
        {
            "D501005001",
            "D501005002",
            "D501005003",
            "D501005004",
            "D501005005",
            "D501005006",
            "D501005007",
            "D501005008",
            "D501005009",
            "D501005010",
            "D501005011",
            "D501005012",
            "D501005013",
            "D501005014",
            "D501005015",
            "D501005016",
            "D501005017",
            "D501005018",
            "D501005019",
            "D501005020"
        },
        "Electric Panel"
    ),
    // Missing Sewage Pipe
    ignoreFACWWP = {
        353003,
        401204,
        401202,
        408004,
        401302,
        401609,
        358001,
        404002,
        404003,
        404004,
        404005,
        201001,
        407702,
        407504,
        354105,
        408400,
        358000,
        358015,
        355002
    },
    badWWPT = HandleMissingItems(mrgBaseAsset, ignoreFACWWP, {"D203001001"}, "Waste Water Pipe"),
    // Missing Water Pipe
    ignoreFACWP = {
        353003,
        401204,
        401202,
        408004,
        401302,
        401609,
        358001,
        404002,
        404003,
        404004,
        404005,
        201001,
        407702,
        407504,
        358015,
        358000,
        354105
    },
    badWPT = HandleMissingItems(mrgBaseAsset, ignoreFACWP, {"D202001001", "D202001002", "D202001003"}, "Water Pipe"),
    // Missing HVAC Ducting
    ignoreFACDuct = {
        353003,
        355003,
        401204,
        401202,
        408004,
        401302,
        401609,
        358001,
        404002,
        404003,
        404004,
        404005,
        201001,
        407702,
        407504,
        354105,
        354107,
        358015,
        358000,
        355002
    },
    badDuctT = HandleMissingItems(mrgBaseAsset, ignoreFACDuct, {"D304001011"}, "HVAC Ducting"),
    //********************************************** MEP **************************************************************************************************************
    // Merge all validation tables.
    lst = List.RemoveNulls(
        {badRIT, badPHSizeT, badSizeT, badWireT, badEPT, badWWPT, badWPT, badDuctT, grpSlabT, dupLstT}
    ),
    output1 = Table.Sort(Table.Combine(lst), {"Inventoried By", "Asset Name", "Notes"}),
    output2 = Table.RemoveColumns(output1, {"FAC Code"}),
    output = Table.ReorderColumns(
        output2,
        {
            "Asset Name",
            "Classification.ID",
            "Year Built",
            "Year Installed",
            "Asset Size",
            "Size/QTY",
            "Section",
            "Count",
            "Notes",
            "Inventoried By"
        },
        MissingField.Ignore
    )
in
    output