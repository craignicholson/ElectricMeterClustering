USE MDM
SET NOCOUNT ON
IF OBJECT_ID('tempdb..#data_kwh') IS NOT NULL DROP TABLE #data_kwh
IF OBJECT_ID('tempdb..#LocationReadValueMax') IS NOT NULL DROP TABLE #LocationReadValueMax
IF OBJECT_ID('tempdb..#data_summary') IS NOT NULL DROP TABLE #data_summary
IF OBJECT_ID('tempdb..#data_total') IS NOT NULL DROP TABLE #data_total
IF OBJECT_ID('tempdb..#model') IS NOT NULL DROP TABLE #model
IF OBJECT_ID('tempdb..#meters') IS NOT NULL DROP TABLE #meters
IF OBJECT_ID('tempdb..#match_results') IS NOT NULL DROP TABLE #match_results

SELECT  
      h.ReadLogDate     
    , d.ReadDate           
    , d.Readvalue      
    , h.Uom
    , d.ReadQualityCode  
    , d.RecordInterval
    , d.VeeFlag
    , d.ChannelStatus
    , s.SubstationName  SubstationName  
    , h.MeterIdentifier
    , l.LocationNumber  
INTO #data_kwh
FROM mdm.dbo.meterreadintervalheader h  
    INNER JOIN mdm.dbo.meter m  
    ON m.meteridentifier = h.meteridentifier    
    INNER JOIN mdm.dbo.MeterReadIntervalDetail d  
    ON d.meterreadintervalheaderid = h.meterreadintervalheaderid  
    INNER JOIN mdm.dbo.electricmeters em  
    ON em.meteridentifier= m.meteridentifier 
    INNER JOIN mdm.dbo.location l  
    ON l.locationid = m.locationid  
    INNER JOIN mdm.dbo.substation s  
    ON s.substationid = l.substationid  
WHERE 
    h.readlogdate >= '2018-01-01' 
    AND h.readlogdate < '2018-02-01'
    AND h.uom = 'kWh'
	--AND l.LocationNumber IN ('4191826','1751219')
    --AND d.ReadQualityCode = '3' --Good Reads Only for now


-- get the max for each location
SELECT   
      max(Readvalue)  [max_per_group]  
    , LocationNumber  
INTO #LocationReadValueMax
FROM #data_kwh 
GROUP BY LocationNumber


-- Get a Summary of the data
-- SELECT COUNT(*) FROM #data_summary
IF OBJECT_ID('tempdb..#data_summary') IS NOT NULL DROP TABLE #data_summary
SELECT  
      convert(varchar(20), ReadDate, 8)  AS 'hhmm'       
    , Uom
    , #data_kwh.LocationNumber  
    , MeterIdentifier
    , avg(Readvalue) mean_value
    --, median(Readvalue) median
    , min(Readvalue) min_value
    , max(Readvalue) max_value
    , sum(Readvalue) sum_value
    , AVG(max_per_group) scaled_mean
    , STDEV(ReadValue) std  
    , NULL AS scaled_value_max
    , NULL AS scaled_value_sd
    , COUNT(*) n
INTO #data_summary
FROM #data_kwh
INNER JOIN #LocationReadValueMax
    ON #LocationReadValueMax.LocationNumber = #data_kwh.LocationNumber
GROUP BY 
      convert(varchar(20), ReadDate, 8)       
    , Uom
    , #data_kwh.LocationNumber  
    , MeterIdentifier

IF OBJECT_ID('tempdb..#data_total') IS NOT NULL DROP TABLE #data_total
SELECT 
      LocationNumber
    , MeterIdentifier
    , SUM(n) intervals
    , 2976 expected 
INTO #data_total    
FROM 
#data_summary
GROUP BY 
    LocationNumber,
    MeterIdentifier

--SELECT * FROM #data_total
--SELECT * FROM #data_summary

 -- Remove Bad Locations, without expected interval counts
DELETE FROM #data_summary
WHERE LocationNumber 
    IN (SELECT LocationNumber FROM #data_total WHERE intervals < expected)  --2976

-- create scaled values b/c this is where the $ is ... 
UPDATE #data_summary
SET 
    scaled_value_max = mean_value / nullif(max_value, 0)
    --,scaled_value_sd  = mean_value / std

-- Get all the LocationNumbers, iterate over them
DECLARE @Model_LocationNumber VARCHAR(50) 
DECLARE @LocationNumber VARCHAR(50) 
DECLARE @percent_diff DECIMAL(18,5)
DECLARE cursor_meters CURSOR FOR  
SELECT LocationNumber FROM #data_summary GROUP BY LocationNumber

-- Get the Model another cursor here... dang... b/c we can have multiple models
SELECT @Model_LocationNumber = 4191826
SELECT * INTO #model FROM #data_summary WHERE LocationNumber = @Model_LocationNumber

OPEN cursor_meters   
FETCH NEXT FROM cursor_meters INTO @LocationNumber   
WHILE @@FETCH_STATUS = 0   
BEGIN    
    -- Compare model and this location
    SELECT   #model.hhmm model_hhmm
           , t.hhmm sample_hhmm
           , #model.mean_value model_mean_value
           , t.mean_value sample_mean_value
           , (#model.mean_value - t.mean_value) / NULLIF( ((#model.mean_value + t.mean_value)/2),0) AS percent_diff
    INTO #match_results
    FROM #model
    INNER JOIN 
        (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumber = @LocationNumber
         AND LocationNumber !=  @Model_LocationNumber
         ) AS t
         ON t.hhmm = #model.hhmm

    -- Get the total percent_diff
    SElECT @percent_diff = SUM(percent_diff) FROM #match_results
    -- if percent_diff is < X (idk, need to test this out) save result as matching somewhere
	-- TODO make 10 a setting
	-- TODO needs a batch ID
    if (ABS(@percent_diff) < 10)
    BEGIN
        PRINT ('MATCH FOUND -> Model LN : ' + @Model_LocationNumber + '| LocationNumber : ' + @LocationNumber +  ' | percent_diff : ' + CAST(@percent_diff AS VARCHAR))
		INSERT INTO   MDM.dbo.Simularities_Results 
			SELECT    @Model_LocationNumber
					, @LocationNumber
					, @percent_diff
					, 10
					, '2018-01-01'
					, '2018-02-01'
					, 'king of pain'
					, GetDate()
	END

    IF OBJECT_ID('tempdb..#match_results') IS NOT NULL DROP TABLE #match_results
    FETCH NEXT FROM cursor_meters INTO @LocationNumber  
    

END   
CLOSE cursor_meters   
DEALLOCATE cursor_meters
SET NOCOUNT OFF

/*review
SELECT * FROM #data_summary

MATCH FOUND -> Model LN : 118419| LocationNumber : 118419 | percent_diff : 0.00000
    SELECT   model.hhmm model_hhmm
           , t.hhmm sample_hhmm
           , model.mean_value model_mean_value
           , t.mean_value sample_mean_value
           , (model.mean_value - t.mean_value) / NULLIF( ((model.mean_value + t.mean_value)/2),0) AS percent_diff
    FROM (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumber = 4191826) AS model
    INNER JOIN 
        (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumbear = 1751219) AS t
         ON t.hhmm = model.hhmm

    SELECT   
          SUM((model.mean_value - t.mean_value) / NULLIF( ((model.mean_value + t.mean_value)/2),0)) AS percent_diff
    FROM (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumber = 4191826) AS model
    INNER JOIN 
        (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumber = 1751219) AS t
         ON t.hhmm = model.hhmm
*/


USE MDM
SET NOCOUNT ON
IF OBJECT_ID('tempdb..#data_kwh') IS NOT NULL DROP TABLE #data_kwh
IF OBJECT_ID('tempdb..#LocationReadValueMax') IS NOT NULL DROP TABLE #LocationReadValueMax
IF OBJECT_ID('tempdb..#data_summary') IS NOT NULL DROP TABLE #data_summary
IF OBJECT_ID('tempdb..#data_total') IS NOT NULL DROP TABLE #data_total
IF OBJECT_ID('tempdb..#model') IS NOT NULL DROP TABLE #model
IF OBJECT_ID('tempdb..#meters') IS NOT NULL DROP TABLE #meters
IF OBJECT_ID('tempdb..#match_results') IS NOT NULL DROP TABLE #match_results

SELECT  
      h.ReadLogDate     
    , d.ReadDate           
    , d.Readvalue      
    , h.Uom
    , d.ReadQualityCode  
    , d.RecordInterval
    , d.VeeFlag
    , d.ChannelStatus
    , s.SubstationName  SubstationName  
    , h.MeterIdentifier
    , l.LocationNumber  
INTO #data_kwh
FROM mdm.dbo.meterreadintervalheader h  
    INNER JOIN mdm.dbo.meter m  
    ON m.meteridentifier = h.meteridentifier    
    INNER JOIN mdm.dbo.MeterReadIntervalDetail d  
    ON d.meterreadintervalheaderid = h.meterreadintervalheaderid  
    INNER JOIN mdm.dbo.electricmeters em  
    ON em.meteridentifier= m.meteridentifier 
    INNER JOIN mdm.dbo.location l  
    ON l.locationid = m.locationid  
    INNER JOIN mdm.dbo.substation s  
    ON s.substationid = l.substationid  
WHERE 
    h.readlogdate >= '2018-01-01' 
    AND h.readlogdate < '2018-02-01'
    AND h.uom = 'kWh'
	--AND l.LocationNumber IN ('4191826','1751219')
    --AND d.ReadQualityCode = '3' --Good Reads Only for now


-- get the max for each location
SELECT   
      max(Readvalue)  [max_per_group]  
    , LocationNumber  
INTO #LocationReadValueMax
FROM #data_kwh 
GROUP BY LocationNumber


-- Get a Summary of the data
-- SELECT COUNT(*) FROM #data_summary
IF OBJECT_ID('tempdb..#data_summary') IS NOT NULL DROP TABLE #data_summary
SELECT  
      convert(varchar(20), ReadDate, 8)  AS 'hhmm'       
    , Uom
    , #data_kwh.LocationNumber  
    , MeterIdentifier
    , avg(Readvalue) mean_value
    --, median(Readvalue) median
    , min(Readvalue) min_value
    , max(Readvalue) max_value
    , sum(Readvalue) sum_value
    , AVG(max_per_group) scaled_mean
    , STDEV(ReadValue) std  
    , NULL AS scaled_value_max
    , NULL AS scaled_value_sd
    , COUNT(*) n
INTO #data_summary
FROM #data_kwh
INNER JOIN #LocationReadValueMax
    ON #LocationReadValueMax.LocationNumber = #data_kwh.LocationNumber
GROUP BY 
      convert(varchar(20), ReadDate, 8)       
    , Uom
    , #data_kwh.LocationNumber  
    , MeterIdentifier

IF OBJECT_ID('tempdb..#data_total') IS NOT NULL DROP TABLE #data_total
SELECT 
      LocationNumber
    , MeterIdentifier
    , SUM(n) intervals
    , 2976 expected 
INTO #data_total    
FROM 
#data_summary
GROUP BY 
    LocationNumber,
    MeterIdentifier

--SELECT * FROM #data_total
--SELECT * FROM #data_summary

 -- Remove Bad Locations, without expected interval counts
DELETE FROM #data_summary
WHERE LocationNumber 
    IN (SELECT LocationNumber FROM #data_total WHERE intervals < expected)  --2976

-- create scaled values b/c this is where the $ is ... 
UPDATE #data_summary
SET 
    scaled_value_max = mean_value / nullif(max_value, 0)
    --,scaled_value_sd  = mean_value / std

-- Get all the LocationNumbers, iterate over them
DECLARE @Model_LocationNumber VARCHAR(50) 
DECLARE @LocationNumber VARCHAR(50) 
DECLARE @percent_diff DECIMAL(18,5)
DECLARE cursor_meters CURSOR FOR  
SELECT LocationNumber FROM #data_summary GROUP BY LocationNumber

-- Get the Model another cursor here... dang... b/c we can have multiple models
SELECT @Model_LocationNumber = 4191826
SELECT * INTO #model FROM #data_summary WHERE LocationNumber = @Model_LocationNumber

OPEN cursor_meters   
FETCH NEXT FROM cursor_meters INTO @LocationNumber   
WHILE @@FETCH_STATUS = 0   
BEGIN    
    -- Compare model and this location
    SELECT   #model.hhmm model_hhmm
           , t.hhmm sample_hhmm
           , #model.scaled_value_max model_mean_value
           , t.scaled_value_max sample_mean_value
           , (#model.scaled_value_max - t.scaled_value_max) / NULLIF(((#model.scaled_value_max + t.scaled_value_max)/2),0) AS percent_diff
    INTO #match_results
    FROM #model
    INNER JOIN 
        (SELECT hhmm, mean_value, scaled_value_max,LocationNumber 
         FROM #data_summary 
         WHERE LocationNumber = @LocationNumber
         AND LocationNumber !=  @Model_LocationNumber
         ) AS t
         ON t.hhmm = #model.hhmm

    -- Get the total percent_diff
    SElECT @percent_diff = SUM(percent_diff) FROM #match_results
    -- if percent_diff is < X (idk, need to test this out) save result as matching somewhere
	-- TODO make 10 a setting
	-- TODO needs a batch ID
    if (ABS(@percent_diff) < 10)
    BEGIN
        PRINT ('MATCH FOUND -> Model LN : ' + @Model_LocationNumber + '| LocationNumber : ' + @LocationNumber +  ' | percent_diff : ' + CAST(@percent_diff AS VARCHAR))
		INSERT INTO   MDM.dbo.Simularities_Results 
			SELECT    @Model_LocationNumber
					, @LocationNumber
					, @percent_diff
					, 10
					, '2018-01-01'
					, '2018-02-01'
					, 'king of pain'
					, GetDate()
	END

    IF OBJECT_ID('tempdb..#match_results') IS NOT NULL DROP TABLE #match_results
    FETCH NEXT FROM cursor_meters INTO @LocationNumber  
    

END   
CLOSE cursor_meters   
DEALLOCATE cursor_meters
SET NOCOUNT OFF

/*review
SELECT * FROM #data_summary

MATCH FOUND -> Model LN : 118419| LocationNumber : 118419 | percent_diff : 0.00000
    SELECT   model.hhmm model_hhmm
           , t.hhmm sample_hhmm
           , model.mean_value model_mean_value
           , t.mean_value sample_mean_value
           , (model.mean_value - t.mean_value) / NULLIF( ((model.mean_value + t.mean_value)/2),0) AS percent_diff
    FROM (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumber = 4191826) AS model
    INNER JOIN 
        (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumbear = 1751219) AS t
         ON t.hhmm = model.hhmm

    SELECT   
          SUM((model.mean_value - t.mean_value) / NULLIF( ((model.mean_value + t.mean_value)/2),0)) AS percent_diff
    FROM (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumber = 4191826) AS model
    INNER JOIN 
        (SELECT hhmm, mean_value, LocationNumber 
         FROM #data_summary 
         WHERE LocationNumber = 1751219) AS t
         ON t.hhmm = model.hhmm
*/



MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051712 | percent_diff : -6.08537
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4741520 | percent_diff : -2.82330
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5265000 | percent_diff : 4.16717
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400036 | percent_diff : -7.43352
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3201860 | percent_diff : 9.56820
MATCH FOUND -> Model LN : 4191826| LocationNumber : 441680 | percent_diff : -0.47297
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242660 | percent_diff : 6.61445
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390770 | percent_diff : -0.15387
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740713 | percent_diff : 8.43900
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1590638 | percent_diff : -3.64170
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1535381 | percent_diff : -4.85353
MATCH FOUND -> Model LN : 4191826| LocationNumber : 327980 | percent_diff : -4.75063
MATCH FOUND -> Model LN : 4191826| LocationNumber : 70320 | percent_diff : -5.54214
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531910 | percent_diff : -0.66225
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4092660 | percent_diff : -6.71299
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3364480 | percent_diff : 3.33616
MATCH FOUND -> Model LN : 4191826| LocationNumber : 655100 | percent_diff : 6.02122
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2100653 | percent_diff : 3.58889
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1710620 | percent_diff : 5.08418
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1512225 | percent_diff : 8.16244
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4201040 | percent_diff : 7.69339
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1792701 | percent_diff : -7.74836
MATCH FOUND -> Model LN : 4191826| LocationNumber : 46540 | percent_diff : -9.61216
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4706390 | percent_diff : 1.35331
MATCH FOUND -> Model LN : 4191826| LocationNumber : 885955 | percent_diff : -2.34667
MATCH FOUND -> Model LN : 4191826| LocationNumber : 384070 | percent_diff : -3.24632
MATCH FOUND -> Model LN : 4191826| LocationNumber : 480965 | percent_diff : 7.66654
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4583840 | percent_diff : 5.46087
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3415800 | percent_diff : -8.62149
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1702405 | percent_diff : 5.42741
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4090370 | percent_diff : -3.32791
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3300820 | percent_diff : 7.46928
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242310 | percent_diff : 2.82974
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3451060 | percent_diff : 5.30744
MATCH FOUND -> Model LN : 4191826| LocationNumber : 801698 | percent_diff : 0.48725
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431365 | percent_diff : 0.87812
MATCH FOUND -> Model LN : 4191826| LocationNumber : 92340 | percent_diff : -8.96931
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466250 | percent_diff : -6.21688
MATCH FOUND -> Model LN : 4191826| LocationNumber : 442490 | percent_diff : 4.20543
MATCH FOUND -> Model LN : 4191826| LocationNumber : 470254 | percent_diff : -4.54234
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3410670 | percent_diff : 9.09450
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2041452 | percent_diff : -9.33774
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1522390 | percent_diff : 9.49057
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2137440 | percent_diff : -5.49702
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580900 | percent_diff : -0.22564
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1731938 | percent_diff : 8.38612
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1770690 | percent_diff : 3.36338
MATCH FOUND -> Model LN : 4191826| LocationNumber : 445865 | percent_diff : 1.62426
MATCH FOUND -> Model LN : 4191826| LocationNumber : 134800 | percent_diff : -7.74168
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1510748 | percent_diff : -3.69258
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464380 | percent_diff : 9.71330
MATCH FOUND -> Model LN : 4191826| LocationNumber : 692708 | percent_diff : 4.82247
MATCH FOUND -> Model LN : 4191826| LocationNumber : 444770 | percent_diff : -0.24743
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382720 | percent_diff : 0.92136
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4162700 | percent_diff : 1.74699
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4001470 | percent_diff : -0.15419
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740427 | percent_diff : 9.09209
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4001210 | percent_diff : -0.27779
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4013165 | percent_diff : -8.00784
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4741490 | percent_diff : -5.79827
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1690562 | percent_diff : 7.51690
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4064460 | percent_diff : 9.68812
MATCH FOUND -> Model LN : 4191826| LocationNumber : 465280 | percent_diff : 7.20475
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4740990 | percent_diff : 0.31137
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580495 | percent_diff : 0.30218
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4570521 | percent_diff : 0.08539
MATCH FOUND -> Model LN : 4191826| LocationNumber : 521875 | percent_diff : -2.20315
MATCH FOUND -> Model LN : 4191826| LocationNumber : 373285 | percent_diff : 1.07226
MATCH FOUND -> Model LN : 4191826| LocationNumber : 465680 | percent_diff : 1.02883
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4583650 | percent_diff : 7.52018
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4152200 | percent_diff : -9.09220
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1561268 | percent_diff : -4.65946
MATCH FOUND -> Model LN : 4191826| LocationNumber : 157480 | percent_diff : 3.96479
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1531136 | percent_diff : 6.61196
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5600370 | percent_diff : 1.38545
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3454810 | percent_diff : 0.75601
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4581500 | percent_diff : 5.15084
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3052197 | percent_diff : -5.87144
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1590926 | percent_diff : -2.84916
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451550 | percent_diff : 6.89495
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4430350 | percent_diff : -7.16786
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1721330 | percent_diff : -1.32276
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1760540 | percent_diff : 8.56986
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3454054 | percent_diff : 9.74067
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3082010 | percent_diff : -7.85339
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400059 | percent_diff : -8.77677
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4071300 | percent_diff : 9.45100
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4211770 | percent_diff : -2.57543
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4430520 | percent_diff : 6.08992
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3362500 | percent_diff : -2.52602
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2197041 | percent_diff : -3.06163
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1990315 | percent_diff : 3.91090
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4286680 | percent_diff : 3.98851
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4300620 | percent_diff : 2.24814
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740390 | percent_diff : -5.19152
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4430180 | percent_diff : 6.52285
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3774380 | percent_diff : -4.70159
MATCH FOUND -> Model LN : 4191826| LocationNumber : 444618 | percent_diff : 4.67559
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4581750 | percent_diff : 3.20789
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051724 | percent_diff : -0.45985
MATCH FOUND -> Model LN : 4191826| LocationNumber : 375205 | percent_diff : -9.38743
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4013180 | percent_diff : 1.38687
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464200 | percent_diff : 4.96904
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4281470 | percent_diff : 6.83841
MATCH FOUND -> Model LN : 4191826| LocationNumber : 463330 | percent_diff : 4.63477
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1650323 | percent_diff : -8.32441
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2191059 | percent_diff : 9.61076
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4091280 | percent_diff : 6.64914
MATCH FOUND -> Model LN : 4191826| LocationNumber : 388665 | percent_diff : 6.69172
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4052230 | percent_diff : -4.53793
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1780693 | percent_diff : -7.08566
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3410880 | percent_diff : 4.41518
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4672320 | percent_diff : 6.24946
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1910265 | percent_diff : 6.66453
MATCH FOUND -> Model LN : 4191826| LocationNumber : 897300 | percent_diff : 0.32900
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3453850 | percent_diff : 1.54036
MATCH FOUND -> Model LN : 4191826| LocationNumber : 383440 | percent_diff : -1.56922
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3230490 | percent_diff : -8.03283
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1553150 | percent_diff : 0.05897
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466040 | percent_diff : 2.86616
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2203200 | percent_diff : 5.89146
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390940 | percent_diff : -1.68056
MATCH FOUND -> Model LN : 4191826| LocationNumber : 443960 | percent_diff : -6.94723
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1710997 | percent_diff : -5.66999
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4241345 | percent_diff : -0.02590
MATCH FOUND -> Model LN : 4191826| LocationNumber : 81550 | percent_diff : 1.84021
MATCH FOUND -> Model LN : 4191826| LocationNumber : 621230 | percent_diff : -0.52713
MATCH FOUND -> Model LN : 4191826| LocationNumber : 410390 | percent_diff : 6.27682
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561440 | percent_diff : -1.92825
MATCH FOUND -> Model LN : 4191826| LocationNumber : 378365 | percent_diff : -4.43837
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4014920 | percent_diff : -6.81042
MATCH FOUND -> Model LN : 4191826| LocationNumber : 631013 | percent_diff : 6.91754
MATCH FOUND -> Model LN : 4191826| LocationNumber : 379165 | percent_diff : -9.95649
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1611103 | percent_diff : 0.87394
MATCH FOUND -> Model LN : 4191826| LocationNumber : 661825 | percent_diff : -6.39622
MATCH FOUND -> Model LN : 4191826| LocationNumber : 34140 | percent_diff : -2.07096
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1690388 | percent_diff : 9.37848
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1533034 | percent_diff : 8.25983
MATCH FOUND -> Model LN : 4191826| LocationNumber : 442730 | percent_diff : -4.28039
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431510 | percent_diff : -6.42672
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3453963 | percent_diff : -8.90545
MATCH FOUND -> Model LN : 4191826| LocationNumber : 413940 | percent_diff : -3.57409
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4021910 | percent_diff : 9.89280
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2140255 | percent_diff : 8.32814
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4260120 | percent_diff : -3.55965
MATCH FOUND -> Model LN : 4191826| LocationNumber : 90265 | percent_diff : 4.75745
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4114010 | percent_diff : -5.02184
MATCH FOUND -> Model LN : 4191826| LocationNumber : 869012 | percent_diff : 4.94846
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4295511 | percent_diff : 6.78802
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051736 | percent_diff : -7.73849
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051010 | percent_diff : 8.80275
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4473206 | percent_diff : -1.03349
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1580310 | percent_diff : 7.23944
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4672475 | percent_diff : 5.71064
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3072878 | percent_diff : 2.55750
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2041308 | percent_diff : 1.09489
MATCH FOUND -> Model LN : 4191826| LocationNumber : 470640 | percent_diff : 8.85289
MATCH FOUND -> Model LN : 4191826| LocationNumber : 22140 | percent_diff : -0.00216
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1621175 | percent_diff : 4.48998
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4012585 | percent_diff : 3.58296
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382900 | percent_diff : -5.72880
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531501 | percent_diff : -2.84976
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420151 | percent_diff : 7.88384
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390755 | percent_diff : 8.74806
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4075000 | percent_diff : 6.99469
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4564155 | percent_diff : 8.86814
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420200 | percent_diff : 7.46239
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1751305 | percent_diff : -2.69602
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4081630 | percent_diff : -3.93500
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3362910 | percent_diff : -8.41078
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1500410 | percent_diff : -2.56492
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9081740 | percent_diff : 3.05100
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1530160 | percent_diff : -7.42758
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1581652 | percent_diff : 7.65822
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530621 | percent_diff : -8.98925
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1501225 | percent_diff : 8.70895
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4416240 | percent_diff : -2.44914
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530700 | percent_diff : -1.95614
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2209003 | percent_diff : 2.06434
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4164650 | percent_diff : 6.07988
MATCH FOUND -> Model LN : 4191826| LocationNumber : 342160 | percent_diff : 7.29060
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3035180 | percent_diff : 6.83751
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1777630 | percent_diff : -2.63046
MATCH FOUND -> Model LN : 4191826| LocationNumber : 163350 | percent_diff : 4.59694
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431650 | percent_diff : 5.17243
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1913035 | percent_diff : -7.49665
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1535375 | percent_diff : -5.11073
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4443376 | percent_diff : -7.59716
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165510 | percent_diff : -2.89664
MATCH FOUND -> Model LN : 4191826| LocationNumber : 80830 | percent_diff : -2.41181
MATCH FOUND -> Model LN : 4191826| LocationNumber : 475640 | percent_diff : -1.75944
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4323010 | percent_diff : 7.30839
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532965 | percent_diff : 0.29956
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1780344 | percent_diff : -0.75862
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240755 | percent_diff : 2.58209
MATCH FOUND -> Model LN : 4191826| LocationNumber : 131550 | percent_diff : 9.48292
MATCH FOUND -> Model LN : 4191826| LocationNumber : 130170 | percent_diff : -4.71467
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4021210 | percent_diff : 8.56653
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1560880 | percent_diff : 0.56806
MATCH FOUND -> Model LN : 4191826| LocationNumber : 378765 | percent_diff : 0.28650
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9100520 | percent_diff : 1.60548
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531430 | percent_diff : -9.10107
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2193159 | percent_diff : -3.82581
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9071043 | percent_diff : 8.19862
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2070900 | percent_diff : -6.46185
MATCH FOUND -> Model LN : 4191826| LocationNumber : 452360 | percent_diff : 7.06798
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5331850 | percent_diff : -8.29023
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1640238 | percent_diff : 6.80603
MATCH FOUND -> Model LN : 4191826| LocationNumber : 467000 | percent_diff : -6.66016
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242510 | percent_diff : 0.54752
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4626360 | percent_diff : 5.01592
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1710301 | percent_diff : -9.72453
MATCH FOUND -> Model LN : 4191826| LocationNumber : 452876 | percent_diff : -6.85631
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3413785 | percent_diff : 3.39587
MATCH FOUND -> Model LN : 4191826| LocationNumber : 581732 | percent_diff : -1.90768
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360697 | percent_diff : 9.98873
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4583740 | percent_diff : 6.16346
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4065880 | percent_diff : 6.21029
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4706060 | percent_diff : 1.42145
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4243420 | percent_diff : 4.50228
MATCH FOUND -> Model LN : 4191826| LocationNumber : 869023 | percent_diff : -9.75030
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165417 | percent_diff : 7.14738
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3364210 | percent_diff : -9.91738
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740747 | percent_diff : -6.70732
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450850 | percent_diff : -5.20508
MATCH FOUND -> Model LN : 4191826| LocationNumber : 263520 | percent_diff : 5.72824
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4012820 | percent_diff : -5.49360
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1780271 | percent_diff : -4.01531
MATCH FOUND -> Model LN : 4191826| LocationNumber : 462460 | percent_diff : 8.99225
MATCH FOUND -> Model LN : 4191826| LocationNumber : 388180 | percent_diff : 8.22741
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450640 | percent_diff : -5.66066
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1711512 | percent_diff : -6.80652
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2195176 | percent_diff : 9.39432
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3363130 | percent_diff : -4.37557
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2120864 | percent_diff : 0.57817
MATCH FOUND -> Model LN : 4191826| LocationNumber : 481225 | percent_diff : 3.25976
MATCH FOUND -> Model LN : 4191826| LocationNumber : 371525 | percent_diff : -1.13355
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1651260 | percent_diff : 8.03177
MATCH FOUND -> Model LN : 4191826| LocationNumber : 376245 | percent_diff : 4.37706
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1030300 | percent_diff : 7.26550
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4564590 | percent_diff : 2.97199
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1765021 | percent_diff : -7.01899
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447830 | percent_diff : 2.76991
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4022320 | percent_diff : 1.73673
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4010160 | percent_diff : 0.43144
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3363730 | percent_diff : 7.25941
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1761505 | percent_diff : -4.89596
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4741180 | percent_diff : 5.49009
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4740290 | percent_diff : 5.67203
MATCH FOUND -> Model LN : 4191826| LocationNumber : 581720 | percent_diff : 7.69210
MATCH FOUND -> Model LN : 4191826| LocationNumber : 444800 | percent_diff : 3.75239
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1751321 | percent_diff : 7.02684
MATCH FOUND -> Model LN : 4191826| LocationNumber : 383780 | percent_diff : 9.50505
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390796 | percent_diff : 6.35494
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580639 | percent_diff : 7.43119
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1779604 | percent_diff : -0.51043
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3413340 | percent_diff : 7.41697
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360695 | percent_diff : -4.48879
MATCH FOUND -> Model LN : 4191826| LocationNumber : 371795 | percent_diff : 1.04179
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4011880 | percent_diff : 4.02980
MATCH FOUND -> Model LN : 4191826| LocationNumber : 53030 | percent_diff : -0.98886
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3031236 | percent_diff : -3.77590
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1702150 | percent_diff : -4.76159
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4050610 | percent_diff : 9.21310
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1571166 | percent_diff : -2.80254
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4524055 | percent_diff : 3.66316
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1591441 | percent_diff : 1.05733
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3203630 | percent_diff : 4.12155
MATCH FOUND -> Model LN : 4191826| LocationNumber : 273280 | percent_diff : 8.77893
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9058100 | percent_diff : -0.76350
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4560685 | percent_diff : 5.01395
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531290 | percent_diff : -9.21499
MATCH FOUND -> Model LN : 4191826| LocationNumber : 864600 | percent_diff : 1.03145
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360663 | percent_diff : 7.86217
MATCH FOUND -> Model LN : 4191826| LocationNumber : 145010 | percent_diff : 1.41297
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1620202 | percent_diff : 0.70439
MATCH FOUND -> Model LN : 4191826| LocationNumber : 452570 | percent_diff : -2.44259
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2151404 | percent_diff : 6.33009
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1535473 | percent_diff : -7.37053
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5443650 | percent_diff : -0.82838
MATCH FOUND -> Model LN : 4191826| LocationNumber : 592160 | percent_diff : 9.57402
MATCH FOUND -> Model LN : 4191826| LocationNumber : 387880 | percent_diff : 9.82174
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1710345 | percent_diff : 4.54000
MATCH FOUND -> Model LN : 4191826| LocationNumber : 163110 | percent_diff : -2.88236
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4001800 | percent_diff : 9.59223
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461710 | percent_diff : 8.21156
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3363040 | percent_diff : 2.20148
MATCH FOUND -> Model LN : 4191826| LocationNumber : 380090 | percent_diff : -1.90608
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1620412 | percent_diff : -1.62849
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4346240 | percent_diff : 0.55744
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2060382 | percent_diff : 5.99631
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4204915 | percent_diff : 8.27861
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4080490 | percent_diff : 2.76656
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9100640 | percent_diff : -0.45554
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4627000 | percent_diff : -4.58195
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2034632 | percent_diff : -0.80026
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3071530 | percent_diff : -6.68329
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1801089 | percent_diff : -8.98934
MATCH FOUND -> Model LN : 4191826| LocationNumber : 376085 | percent_diff : -4.10760
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4162895 | percent_diff : 6.39815
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1611319 | percent_diff : -6.89607
MATCH FOUND -> Model LN : 4191826| LocationNumber : 431250 | percent_diff : 8.14319
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4403580 | percent_diff : -4.59142
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4432360 | percent_diff : 4.08136
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3071290 | percent_diff : 4.95734
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2172456 | percent_diff : 5.43622
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1721573 | percent_diff : -2.20064
MATCH FOUND -> Model LN : 4191826| LocationNumber : 452780 | percent_diff : 7.38581
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561340 | percent_diff : -6.52416
MATCH FOUND -> Model LN : 4191826| LocationNumber : 372725 | percent_diff : 1.13946
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1511925 | percent_diff : 1.69583
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561950 | percent_diff : 9.34148
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3286443 | percent_diff : 4.18173
MATCH FOUND -> Model LN : 4191826| LocationNumber : 465700 | percent_diff : 4.37377
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4162960 | percent_diff : 6.77388
MATCH FOUND -> Model LN : 4191826| LocationNumber : 840500 | percent_diff : -1.19941
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4243250 | percent_diff : 1.04646
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3455720 | percent_diff : -4.63263
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4432670 | percent_diff : -0.79097
MATCH FOUND -> Model LN : 4191826| LocationNumber : 374365 | percent_diff : -2.62294
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1763510 | percent_diff : 0.81230
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464860 | percent_diff : 7.05837
MATCH FOUND -> Model LN : 4191826| LocationNumber : 473990 | percent_diff : 9.01679
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1006820 | percent_diff : -2.82310
MATCH FOUND -> Model LN : 4191826| LocationNumber : 481085 | percent_diff : 2.89747
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1681539 | percent_diff : 5.80477
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1640573 | percent_diff : -7.35913
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531090 | percent_diff : 1.75091
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2134620 | percent_diff : 5.03553
MATCH FOUND -> Model LN : 4191826| LocationNumber : 460570 | percent_diff : 0.40025
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1781179 | percent_diff : 8.66087
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9060989 | percent_diff : -4.94501
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4241160 | percent_diff : 2.39798
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3230790 | percent_diff : -2.53471
MATCH FOUND -> Model LN : 4191826| LocationNumber : 431950 | percent_diff : 3.70516
MATCH FOUND -> Model LN : 4191826| LocationNumber : 470180 | percent_diff : -0.66829
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4050630 | percent_diff : 9.91861
MATCH FOUND -> Model LN : 4191826| LocationNumber : 243720 | percent_diff : 1.22147
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3363418 | percent_diff : -1.30671
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3225290 | percent_diff : 8.97298
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1641990 | percent_diff : 8.44785
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4013640 | percent_diff : 5.80130
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533332 | percent_diff : 5.39690
MATCH FOUND -> Model LN : 4191826| LocationNumber : 452660 | percent_diff : 2.94081
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451430 | percent_diff : -1.72581
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450700 | percent_diff : 0.87010
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4281680 | percent_diff : -7.29383
MATCH FOUND -> Model LN : 4191826| LocationNumber : 362150 | percent_diff : 1.70578
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4001560 | percent_diff : 3.02815
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2090575 | percent_diff : 0.46950
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533115 | percent_diff : -0.75068
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447707 | percent_diff : -2.99406
MATCH FOUND -> Model LN : 4191826| LocationNumber : 446450 | percent_diff : -9.10812
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4626383 | percent_diff : 6.52437
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4164145 | percent_diff : 5.27712
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2011220 | percent_diff : -4.80697
MATCH FOUND -> Model LN : 4191826| LocationNumber : 471200 | percent_diff : 4.09908
MATCH FOUND -> Model LN : 4191826| LocationNumber : 684440 | percent_diff : -8.23010
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4001212 | percent_diff : -9.16286
MATCH FOUND -> Model LN : 4191826| LocationNumber : 13047 | percent_diff : -2.38734
MATCH FOUND -> Model LN : 4191826| LocationNumber : 33820 | percent_diff : -6.53729
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4601420 | percent_diff : 7.94073
MATCH FOUND -> Model LN : 4191826| LocationNumber : 90140 | percent_diff : -6.38183
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1550205 | percent_diff : 4.42104
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580490 | percent_diff : -2.22639
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3083360 | percent_diff : 3.65075
MATCH FOUND -> Model LN : 4191826| LocationNumber : 204230 | percent_diff : -6.94004
MATCH FOUND -> Model LN : 4191826| LocationNumber : 415440 | percent_diff : -5.43194
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431400 | percent_diff : 6.70381
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450460 | percent_diff : -3.82656
MATCH FOUND -> Model LN : 4191826| LocationNumber : 80840 | percent_diff : 9.90552
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1763466 | percent_diff : -8.54703
MATCH FOUND -> Model LN : 4191826| LocationNumber : 381820 | percent_diff : -9.55893
MATCH FOUND -> Model LN : 4191826| LocationNumber : 692007 | percent_diff : 0.24093
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400049 | percent_diff : -3.21906
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2151215 | percent_diff : -2.67533
MATCH FOUND -> Model LN : 4191826| LocationNumber : 862720 | percent_diff : 6.88358
MATCH FOUND -> Model LN : 4191826| LocationNumber : 71460 | percent_diff : 1.06280
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3283400 | percent_diff : -5.43345
MATCH FOUND -> Model LN : 4191826| LocationNumber : 430680 | percent_diff : -9.55062
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561870 | percent_diff : 8.37223
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562510 | percent_diff : 9.73989
MATCH FOUND -> Model LN : 4191826| LocationNumber : 945390 | percent_diff : -2.40785
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2020904 | percent_diff : 0.15854
MATCH FOUND -> Model LN : 4191826| LocationNumber : 825180 | percent_diff : -2.92697
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4021980 | percent_diff : 2.00534
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451469 | percent_diff : 3.32666
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360205 | percent_diff : 2.86004
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3030450 | percent_diff : 5.22473
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1610950 | percent_diff : 9.54076
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4655020 | percent_diff : -3.84919
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466430 | percent_diff : -7.10257
MATCH FOUND -> Model LN : 4191826| LocationNumber : 383145 | percent_diff : 8.60866
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2140605 | percent_diff : -3.38314
MATCH FOUND -> Model LN : 4191826| LocationNumber : 465520 | percent_diff : 4.92117
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390632 | percent_diff : 9.16083
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4062760 | percent_diff : -4.49001
MATCH FOUND -> Model LN : 4191826| LocationNumber : 561490 | percent_diff : -9.57371
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1502182 | percent_diff : 2.24898
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1751161 | percent_diff : 5.53238
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2060464 | percent_diff : -9.09023
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533220 | percent_diff : 4.45880
MATCH FOUND -> Model LN : 4191826| LocationNumber : 387212 | percent_diff : 0.81868
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3451960 | percent_diff : 4.79537
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4116213 | percent_diff : 9.59002
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4024950 | percent_diff : 4.38508
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3455740 | percent_diff : 2.76956
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4721275 | percent_diff : 4.59893
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4200300 | percent_diff : -7.42430
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431590 | percent_diff : -5.81849
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9050775 | percent_diff : 7.84547
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1620870 | percent_diff : 5.56201
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4080800 | percent_diff : 4.75739
MATCH FOUND -> Model LN : 4191826| LocationNumber : 463060 | percent_diff : 6.29633
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1750409 | percent_diff : -8.68820
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242480 | percent_diff : 4.07507
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4252170 | percent_diff : 7.99963
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531380 | percent_diff : 7.58450
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1651305 | percent_diff : 7.84719
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3282460 | percent_diff : -5.13360
MATCH FOUND -> Model LN : 4191826| LocationNumber : 467390 | percent_diff : 4.32941
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420011 | percent_diff : 1.21069
MATCH FOUND -> Model LN : 4191826| LocationNumber : 783150 | percent_diff : -8.94204
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3364810 | percent_diff : 5.37311
MATCH FOUND -> Model LN : 4191826| LocationNumber : 692704 | percent_diff : 0.47713
MATCH FOUND -> Model LN : 4191826| LocationNumber : 480660 | percent_diff : 2.42545
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1581369 | percent_diff : 5.00856
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2195284 | percent_diff : -5.56299
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561790 | percent_diff : -3.20187
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2070428 | percent_diff : -7.25051
MATCH FOUND -> Model LN : 4191826| LocationNumber : 274060 | percent_diff : 1.21617
MATCH FOUND -> Model LN : 4191826| LocationNumber : 51110 | percent_diff : 6.20161
MATCH FOUND -> Model LN : 4191826| LocationNumber : 481340 | percent_diff : 4.82377
MATCH FOUND -> Model LN : 4191826| LocationNumber : 481135 | percent_diff : -5.78998
MATCH FOUND -> Model LN : 4191826| LocationNumber : 389080 | percent_diff : -0.79351
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2136994 | percent_diff : -7.56063
MATCH FOUND -> Model LN : 4191826| LocationNumber : 198650 | percent_diff : 3.56273
MATCH FOUND -> Model LN : 4191826| LocationNumber : 930590 | percent_diff : 3.99506
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400840 | percent_diff : 9.82843
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2041340 | percent_diff : 3.45738
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400810 | percent_diff : -2.91342
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165980 | percent_diff : -6.07688
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431530 | percent_diff : -7.25069
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4066280 | percent_diff : 5.27396
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447695 | percent_diff : 6.56410
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2196035 | percent_diff : 2.58257
MATCH FOUND -> Model LN : 4191826| LocationNumber : 430900 | percent_diff : -5.47196
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447470 | percent_diff : -9.95447
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4024980 | percent_diff : 3.05078
MATCH FOUND -> Model LN : 4191826| LocationNumber : 581706 | percent_diff : -7.32013
MATCH FOUND -> Model LN : 4191826| LocationNumber : 821880 | percent_diff : -6.14374
MATCH FOUND -> Model LN : 4191826| LocationNumber : 590660 | percent_diff : 9.91537
MATCH FOUND -> Model LN : 4191826| LocationNumber : 454290 | percent_diff : 9.30817
MATCH FOUND -> Model LN : 4191826| LocationNumber : 20850 | percent_diff : 6.46094
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533665 | percent_diff : 9.56802
MATCH FOUND -> Model LN : 4191826| LocationNumber : 472400 | percent_diff : -4.57403
MATCH FOUND -> Model LN : 4191826| LocationNumber : 361585 | percent_diff : -0.24547
MATCH FOUND -> Model LN : 4191826| LocationNumber : 332741 | percent_diff : -3.89838
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382053 | percent_diff : 4.25665
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1535320 | percent_diff : 2.42285
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4013085 | percent_diff : -3.78844
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1581459 | percent_diff : -7.19587
MATCH FOUND -> Model LN : 4191826| LocationNumber : 654100 | percent_diff : -0.90773
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4062960 | percent_diff : -5.80558
MATCH FOUND -> Model LN : 4191826| LocationNumber : 362695 | percent_diff : 7.80165
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4062700 | percent_diff : -9.11922
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1773328 | percent_diff : -1.66047
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400051 | percent_diff : -9.95563
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561390 | percent_diff : -3.35723
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2197008 | percent_diff : 9.93327
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561620 | percent_diff : -4.11860
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1750070 | percent_diff : -0.85317
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532301 | percent_diff : -4.24048
MATCH FOUND -> Model LN : 4191826| LocationNumber : 410470 | percent_diff : -5.86531
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4155350 | percent_diff : 1.04820
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4164900 | percent_diff : 8.17105
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2196365 | percent_diff : -0.59155
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4740970 | percent_diff : 6.71561
MATCH FOUND -> Model LN : 4191826| LocationNumber : 944810 | percent_diff : -1.71883
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1540116 | percent_diff : -0.14995
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4200261 | percent_diff : -8.05145
MATCH FOUND -> Model LN : 4191826| LocationNumber : 449270 | percent_diff : -7.78908
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2209024 | percent_diff : -2.01019
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3031190 | percent_diff : -4.73251
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4415019 | percent_diff : 3.72974
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1501390 | percent_diff : -3.87524
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4361870 | percent_diff : -7.69083
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4093320 | percent_diff : -0.52952
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2120467 | percent_diff : -5.19243
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580643 | percent_diff : -1.13928
MATCH FOUND -> Model LN : 4191826| LocationNumber : 448725 | percent_diff : -7.85905
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4050430 | percent_diff : -1.80763
MATCH FOUND -> Model LN : 4191826| LocationNumber : 702146 | percent_diff : 1.95786
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400260 | percent_diff : 0.26107
MATCH FOUND -> Model LN : 4191826| LocationNumber : 70210 | percent_diff : -2.94962
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165424 | percent_diff : -4.49804
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4640960 | percent_diff : -5.05239
MATCH FOUND -> Model LN : 4191826| LocationNumber : 581646 | percent_diff : 2.06592
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3032496 | percent_diff : 1.55037
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4711010 | percent_diff : 9.29418
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420240 | percent_diff : 7.85967
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4050550 | percent_diff : -3.70317
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2130180 | percent_diff : -1.84877
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3415410 | percent_diff : 2.85674
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4093420 | percent_diff : -9.45313
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740470 | percent_diff : 2.09819
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451310 | percent_diff : -0.82291
MATCH FOUND -> Model LN : 4191826| LocationNumber : 462095 | percent_diff : -9.41443
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2121853 | percent_diff : -1.71120
MATCH FOUND -> Model LN : 4191826| LocationNumber : 33890 | percent_diff : -5.11458
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9090820 | percent_diff : -6.62393
MATCH FOUND -> Model LN : 4191826| LocationNumber : 571609 | percent_diff : 7.90102
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360985 | percent_diff : 7.73861
MATCH FOUND -> Model LN : 4191826| LocationNumber : 376125 | percent_diff : -7.21292
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1778794 | percent_diff : -7.28654
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1732260 | percent_diff : -8.98798
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3045672 | percent_diff : 2.33927
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240920 | percent_diff : 3.50221
MATCH FOUND -> Model LN : 4191826| LocationNumber : 384280 | percent_diff : -7.77015
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1721858 | percent_diff : 9.38717
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165645 | percent_diff : 2.94805
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532326 | percent_diff : 2.78538
MATCH FOUND -> Model LN : 4191826| LocationNumber : 480172 | percent_diff : -8.34498
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3284350 | percent_diff : 0.62252
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464028 | percent_diff : -5.69701
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1720940 | percent_diff : 8.69724
MATCH FOUND -> Model LN : 4191826| LocationNumber : 80770 | percent_diff : -3.20166
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4061040 | percent_diff : 4.52557
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420106 | percent_diff : 0.38908
MATCH FOUND -> Model LN : 4191826| LocationNumber : 550670 | percent_diff : 5.99666
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400775 | percent_diff : -3.82035
MATCH FOUND -> Model LN : 4191826| LocationNumber : 381910 | percent_diff : 3.78636
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4470405 | percent_diff : -3.97568
MATCH FOUND -> Model LN : 4191826| LocationNumber : 421090 | percent_diff : 9.72379
MATCH FOUND -> Model LN : 4191826| LocationNumber : 389500 | percent_diff : -1.67889
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4201160 | percent_diff : -5.51567
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4570565 | percent_diff : 8.26668
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382420 | percent_diff : -2.62359
MATCH FOUND -> Model LN : 4191826| LocationNumber : 320985 | percent_diff : 5.96953
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562570 | percent_diff : 3.62733
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3452620 | percent_diff : 3.77491
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461590 | percent_diff : -1.05830
MATCH FOUND -> Model LN : 4191826| LocationNumber : 60420 | percent_diff : 4.24712
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1776547 | percent_diff : 5.07110
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4162200 | percent_diff : -3.79798
MATCH FOUND -> Model LN : 4191826| LocationNumber : 23390 | percent_diff : 0.02140
MATCH FOUND -> Model LN : 4191826| LocationNumber : 380170 | percent_diff : 9.96607
MATCH FOUND -> Model LN : 4191826| LocationNumber : 362305 | percent_diff : -1.91008
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4414580 | percent_diff : 7.75857
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3415852 | percent_diff : 2.17318
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461328 | percent_diff : -0.05356
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562840 | percent_diff : -9.72031
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450010 | percent_diff : -8.95573
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4574860 | percent_diff : 2.40842
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1930927 | percent_diff : 0.12462
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562790 | percent_diff : 5.98951
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4080680 | percent_diff : -2.17847
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532638 | percent_diff : 2.45254
MATCH FOUND -> Model LN : 4191826| LocationNumber : 374245 | percent_diff : -5.22782
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1580398 | percent_diff : 5.51515
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1571041 | percent_diff : -7.46549
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5333670 | percent_diff : 8.01356
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4164305 | percent_diff : -1.61099
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1601443 | percent_diff : 6.18869
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5333642 | percent_diff : 8.92993
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466100 | percent_diff : -0.41741
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3454075 | percent_diff : -7.86570
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2100940 | percent_diff : -5.51459
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4472200 | percent_diff : -0.88201
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464685 | percent_diff : 0.99649
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4091550 | percent_diff : -9.74091
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3281439 | percent_diff : -1.45944
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1780722 | percent_diff : -8.07829
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1650351 | percent_diff : 8.76380
MATCH FOUND -> Model LN : 4191826| LocationNumber : 630396 | percent_diff : 2.22286
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1681230 | percent_diff : 9.27360
MATCH FOUND -> Model LN : 4191826| LocationNumber : 450290 | percent_diff : -2.71617
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3412110 | percent_diff : 5.96803
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562995 | percent_diff : 7.10124
MATCH FOUND -> Model LN : 4191826| LocationNumber : 123515 | percent_diff : -6.25011
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4626193 | percent_diff : 2.50420
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3415220 | percent_diff : 4.33259
MATCH FOUND -> Model LN : 4191826| LocationNumber : 562780 | percent_diff : 3.22640
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4243400 | percent_diff : 4.96243
MATCH FOUND -> Model LN : 4191826| LocationNumber : 80790 | percent_diff : 3.41969
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4740160 | percent_diff : -3.49153
MATCH FOUND -> Model LN : 4191826| LocationNumber : 841170 | percent_diff : -7.19988
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1500237 | percent_diff : -0.62933
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562850 | percent_diff : 5.75316
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4197605 | percent_diff : -8.27593
MATCH FOUND -> Model LN : 4191826| LocationNumber : 430440 | percent_diff : 3.75751
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165890 | percent_diff : -6.48109
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3451751 | percent_diff : 9.30345
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4096600 | percent_diff : -7.18309
MATCH FOUND -> Model LN : 4191826| LocationNumber : 481250 | percent_diff : -9.05913
MATCH FOUND -> Model LN : 4191826| LocationNumber : 361825 | percent_diff : -6.69802
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3341530 | percent_diff : -6.56211
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4260165 | percent_diff : 6.06216
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2071460 | percent_diff : -1.50441
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466310 | percent_diff : -5.30999
MATCH FOUND -> Model LN : 4191826| LocationNumber : 376065 | percent_diff : 6.87441
MATCH FOUND -> Model LN : 4191826| LocationNumber : 454940 | percent_diff : -4.48410
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1541272 | percent_diff : -8.37435
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1501175 | percent_diff : 8.52696
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1553744 | percent_diff : 4.89297
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4080530 | percent_diff : 1.94596
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533815 | percent_diff : -5.49870
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420154 | percent_diff : 4.12367
MATCH FOUND -> Model LN : 4191826| LocationNumber : 581963 | percent_diff : 5.31633
MATCH FOUND -> Model LN : 4191826| LocationNumber : 474470 | percent_diff : -5.67597
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242030 | percent_diff : -8.21102
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3772580 | percent_diff : 5.00932
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1570691 | percent_diff : -9.32693
MATCH FOUND -> Model LN : 4191826| LocationNumber : 445765 | percent_diff : 1.03540
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400505 | percent_diff : 1.68788
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1541132 | percent_diff : 2.33749
MATCH FOUND -> Model LN : 4191826| LocationNumber : 320140 | percent_diff : -1.49316
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2091270 | percent_diff : -0.25322
MATCH FOUND -> Model LN : 4191826| LocationNumber : 465745 | percent_diff : -0.22428
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533255 | percent_diff : -4.24392
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4013760 | percent_diff : -9.57286
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390145 | percent_diff : -4.66361
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4241000 | percent_diff : 3.44916
MATCH FOUND -> Model LN : 4191826| LocationNumber : 622300 | percent_diff : 6.16141
MATCH FOUND -> Model LN : 4191826| LocationNumber : 454660 | percent_diff : 4.76400
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2084610 | percent_diff : 7.10987
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382360 | percent_diff : 4.92649
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4020500 | percent_diff : -6.62055
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530740 | percent_diff : 3.22938
MATCH FOUND -> Model LN : 4191826| LocationNumber : 381995 | percent_diff : -9.51515
MATCH FOUND -> Model LN : 4191826| LocationNumber : 217830 | percent_diff : -7.34270
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1720325 | percent_diff : 5.23475
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4432510 | percent_diff : 0.90140
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3292520 | percent_diff : -9.31086
MATCH FOUND -> Model LN : 4191826| LocationNumber : 475756 | percent_diff : 3.99146
MATCH FOUND -> Model LN : 4191826| LocationNumber : 389590 | percent_diff : 7.09801
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2090328 | percent_diff : -2.32758
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4080300 | percent_diff : -7.74292
MATCH FOUND -> Model LN : 4191826| LocationNumber : 313795 | percent_diff : -3.06305
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4338120 | percent_diff : -7.01168
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4093860 | percent_diff : 3.34462
MATCH FOUND -> Model LN : 4191826| LocationNumber : 442460 | percent_diff : -4.50542
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1731973 | percent_diff : -9.27694
MATCH FOUND -> Model LN : 4191826| LocationNumber : 445880 | percent_diff : -2.75644
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1620195 | percent_diff : -1.47809
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3361210 | percent_diff : -7.38780
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4002240 | percent_diff : -1.28067
MATCH FOUND -> Model LN : 4191826| LocationNumber : 253290 | percent_diff : -7.07207
MATCH FOUND -> Model LN : 4191826| LocationNumber : 445860 | percent_diff : -5.64094
MATCH FOUND -> Model LN : 4191826| LocationNumber : 450545 | percent_diff : 8.20563
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382630 | percent_diff : 1.04298
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431160 | percent_diff : 4.98086
MATCH FOUND -> Model LN : 4191826| LocationNumber : 33903 | percent_diff : -8.24585
MATCH FOUND -> Model LN : 4191826| LocationNumber : 455390 | percent_diff : -4.58832
MATCH FOUND -> Model LN : 4191826| LocationNumber : 454040 | percent_diff : 8.25308
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1630280 | percent_diff : 3.07368
MATCH FOUND -> Model LN : 4191826| LocationNumber : 611825 | percent_diff : 2.83709
MATCH FOUND -> Model LN : 4191826| LocationNumber : 135700 | percent_diff : -5.94242
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4063000 | percent_diff : 6.79171
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4287185 | percent_diff : -0.19849
MATCH FOUND -> Model LN : 4191826| LocationNumber : 703387 | percent_diff : 3.90920
MATCH FOUND -> Model LN : 4191826| LocationNumber : 473840 | percent_diff : -3.78978
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532324 | percent_diff : 5.89082
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1601477 | percent_diff : 4.27936
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1611915 | percent_diff : 7.96848
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4432650 | percent_diff : -1.75975
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451063 | percent_diff : 6.71033
MATCH FOUND -> Model LN : 4191826| LocationNumber : 604500 | percent_diff : -0.93450
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1501208 | percent_diff : -9.60742
MATCH FOUND -> Model LN : 4191826| LocationNumber : 446300 | percent_diff : 9.79334
MATCH FOUND -> Model LN : 4191826| LocationNumber : 25790 | percent_diff : -6.94943
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4011940 | percent_diff : 8.64618
MATCH FOUND -> Model LN : 4191826| LocationNumber : 462250 | percent_diff : -3.24364
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4403590 | percent_diff : -2.30870
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1620409 | percent_diff : 9.37744
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3779192 | percent_diff : -0.19070
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4430850 | percent_diff : -1.96761
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3411540 | percent_diff : -9.75414
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240757 | percent_diff : -8.82207
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2090558 | percent_diff : 6.25654
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4470445 | percent_diff : -8.00298
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2204019 | percent_diff : 5.53367
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1930772 | percent_diff : -0.54620
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1031020 | percent_diff : -5.50610
MATCH FOUND -> Model LN : 4191826| LocationNumber : 373565 | percent_diff : 5.80805
MATCH FOUND -> Model LN : 4191826| LocationNumber : 468350 | percent_diff : 3.39125
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1991230 | percent_diff : 3.79120
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2085120 | percent_diff : -0.89638
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461540 | percent_diff : -5.09598
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2121830 | percent_diff : -2.81067
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1643780 | percent_diff : -0.13299
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580595 | percent_diff : -1.05919
MATCH FOUND -> Model LN : 4191826| LocationNumber : 293990 | percent_diff : -4.58561
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533082 | percent_diff : 2.77506
MATCH FOUND -> Model LN : 4191826| LocationNumber : 80960 | percent_diff : 0.33501
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4002560 | percent_diff : 6.65283
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4564686 | percent_diff : -0.45619
MATCH FOUND -> Model LN : 4191826| LocationNumber : 481325 | percent_diff : 8.61349
MATCH FOUND -> Model LN : 4191826| LocationNumber : 824800 | percent_diff : -4.70292
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5331320 | percent_diff : 0.44959
MATCH FOUND -> Model LN : 4191826| LocationNumber : 512366 | percent_diff : -8.98394
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3200600 | percent_diff : 8.18227
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2060449 | percent_diff : 0.30066
MATCH FOUND -> Model LN : 4191826| LocationNumber : 388150 | percent_diff : 8.19619
MATCH FOUND -> Model LN : 4191826| LocationNumber : 273160 | percent_diff : 6.75723
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051602 | percent_diff : 8.26870
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4331960 | percent_diff : 9.94392
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4740104 | percent_diff : 0.67749
MATCH FOUND -> Model LN : 4191826| LocationNumber : 385390 | percent_diff : 7.47773
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2120023 | percent_diff : 1.12813
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531040 | percent_diff : 4.22216
MATCH FOUND -> Model LN : 4191826| LocationNumber : 361185 | percent_diff : -6.04379
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5333750 | percent_diff : 0.35905
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447723 | percent_diff : 5.81972
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4066220 | percent_diff : 4.82201
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1522780 | percent_diff : -2.12872
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1590515 | percent_diff : 2.17498
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1630544 | percent_diff : -7.65914
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4050670 | percent_diff : -5.17406
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4241830 | percent_diff : -7.77563
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3144050 | percent_diff : -7.86162
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4203070 | percent_diff : -4.70221
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450490 | percent_diff : 5.79247
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4053800 | percent_diff : 0.58523
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2110778 | percent_diff : 3.02116
MATCH FOUND -> Model LN : 4191826| LocationNumber : 473455 | percent_diff : -7.91657
MATCH FOUND -> Model LN : 4191826| LocationNumber : 580782 | percent_diff : 4.86890
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165434 | percent_diff : 5.42831
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3454048 | percent_diff : 6.94428
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390370 | percent_diff : 7.19499
MATCH FOUND -> Model LN : 4191826| LocationNumber : 386442 | percent_diff : -2.00318
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4164914 | percent_diff : -7.47329
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051830 | percent_diff : 1.30557
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051720 | percent_diff : 1.92117
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4205512 | percent_diff : 9.69877
MATCH FOUND -> Model LN : 4191826| LocationNumber : 581696 | percent_diff : -3.00315
MATCH FOUND -> Model LN : 4191826| LocationNumber : 449572 | percent_diff : 6.58662
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3451690 | percent_diff : -5.32513
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531220 | percent_diff : 1.70670
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4149550 | percent_diff : -6.28068
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4095440 | percent_diff : -7.96002
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1770390 | percent_diff : 0.78215
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1522014 | percent_diff : 5.18749
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9081742 | percent_diff : -4.50555
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4012840 | percent_diff : -2.41072
MATCH FOUND -> Model LN : 4191826| LocationNumber : 131770 | percent_diff : -4.02370
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450880 | percent_diff : 4.34727
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420012 | percent_diff : -7.31167
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4096500 | percent_diff : 0.58408
MATCH FOUND -> Model LN : 4191826| LocationNumber : 474710 | percent_diff : -4.89912
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531544 | percent_diff : 8.11872
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531425 | percent_diff : -4.44528
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420185 | percent_diff : 4.61628
MATCH FOUND -> Model LN : 4191826| LocationNumber : 421430 | percent_diff : -3.84463
MATCH FOUND -> Model LN : 4191826| LocationNumber : 386470 | percent_diff : 9.25586
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240760 | percent_diff : -0.15826
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4400800 | percent_diff : -1.29075
MATCH FOUND -> Model LN : 4191826| LocationNumber : 448160 | percent_diff : 0.76403
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4073630 | percent_diff : 8.09240
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051600 | percent_diff : 9.27754
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4383245 | percent_diff : 9.05776
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390130 | percent_diff : -4.29844
MATCH FOUND -> Model LN : 4191826| LocationNumber : 387700 | percent_diff : 0.04327
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1501425 | percent_diff : -8.30284
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466160 | percent_diff : -9.62158
MATCH FOUND -> Model LN : 4191826| LocationNumber : 463200 | percent_diff : -3.95270
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3550987 | percent_diff : 1.24624
MATCH FOUND -> Model LN : 4191826| LocationNumber : 22350 | percent_diff : 5.45455
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466130 | percent_diff : -6.43635
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3413100 | percent_diff : 1.09899
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390185 | percent_diff : 2.80245
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1770700 | percent_diff : 8.44093
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4066443 | percent_diff : -2.84281
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1553400 | percent_diff : -9.53786
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2041286 | percent_diff : 5.88085
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4013500 | percent_diff : -9.52516
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2110705 | percent_diff : -9.78191
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1580630 | percent_diff : -1.84490
MATCH FOUND -> Model LN : 4191826| LocationNumber : 314425 | percent_diff : 0.28579
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447482 | percent_diff : -1.46719
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2110691 | percent_diff : -8.86570
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4416545 | percent_diff : 1.31957
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4074010 | percent_diff : 9.58249
MATCH FOUND -> Model LN : 4191826| LocationNumber : 460361 | percent_diff : 8.95114
MATCH FOUND -> Model LN : 4191826| LocationNumber : 740715 | percent_diff : -4.92021
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2041451 | percent_diff : 1.80701
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3141260 | percent_diff : 6.99633
MATCH FOUND -> Model LN : 4191826| LocationNumber : 375365 | percent_diff : -1.25656
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1711354 | percent_diff : -7.45221
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3454844 | percent_diff : 3.52260
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580280 | percent_diff : 1.53442
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431010 | percent_diff : 6.74433
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4080260 | percent_diff : 5.74741
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1520851 | percent_diff : 2.13234
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740945 | percent_diff : 5.07517
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3361810 | percent_diff : 2.21567
MATCH FOUND -> Model LN : 4191826| LocationNumber : 935240 | percent_diff : -3.77566
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4082830 | percent_diff : 1.82480
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4640740 | percent_diff : -9.50974
MATCH FOUND -> Model LN : 4191826| LocationNumber : 471025 | percent_diff : 7.66374
MATCH FOUND -> Model LN : 4191826| LocationNumber : 480455 | percent_diff : 8.52845
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382190 | percent_diff : 7.10534
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3274775 | percent_diff : 7.59596
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1941740 | percent_diff : 1.01263
MATCH FOUND -> Model LN : 4191826| LocationNumber : 80680 | percent_diff : -3.87271
MATCH FOUND -> Model LN : 4191826| LocationNumber : 571605 | percent_diff : 5.40965
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1532567 | percent_diff : 5.91745
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451665 | percent_diff : -7.13227
MATCH FOUND -> Model LN : 4191826| LocationNumber : 444110 | percent_diff : 8.51020
MATCH FOUND -> Model LN : 4191826| LocationNumber : 462130 | percent_diff : 7.84090
MATCH FOUND -> Model LN : 4191826| LocationNumber : 446090 | percent_diff : 9.97625
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4301600 | percent_diff : 7.44921
MATCH FOUND -> Model LN : 4191826| LocationNumber : 383120 | percent_diff : 0.75915
MATCH FOUND -> Model LN : 4191826| LocationNumber : 883044 | percent_diff : -0.43175
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400053 | percent_diff : 4.91103
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447110 | percent_diff : -6.06149
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4241510 | percent_diff : -0.07479
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4201980 | percent_diff : -8.26582
MATCH FOUND -> Model LN : 4191826| LocationNumber : 872938 | percent_diff : -2.55257
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4010300 | percent_diff : 5.69868
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461407 | percent_diff : 7.30906
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532985 | percent_diff : 9.03007
MATCH FOUND -> Model LN : 4191826| LocationNumber : 444500 | percent_diff : 7.06454
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532855 | percent_diff : -5.38242
MATCH FOUND -> Model LN : 4191826| LocationNumber : 343990 | percent_diff : 4.09191
MATCH FOUND -> Model LN : 4191826| LocationNumber : 50960 | percent_diff : 2.89451
MATCH FOUND -> Model LN : 4191826| LocationNumber : 941640 | percent_diff : -0.76478
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464320 | percent_diff : -4.80319
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3220440 | percent_diff : 6.98617
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2101146 | percent_diff : -7.74209
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1540395 | percent_diff : 7.75725
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1580304 | percent_diff : -9.01323
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451060 | percent_diff : -0.15137
MATCH FOUND -> Model LN : 4191826| LocationNumber : 383860 | percent_diff : 6.35394
MATCH FOUND -> Model LN : 4191826| LocationNumber : 481550 | percent_diff : 2.34973
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4021420 | percent_diff : 5.20775
MATCH FOUND -> Model LN : 4191826| LocationNumber : 462010 | percent_diff : -4.86884
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165860 | percent_diff : -6.13281
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4082920 | percent_diff : -2.81555
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533130 | percent_diff : -5.89851
MATCH FOUND -> Model LN : 4191826| LocationNumber : 9081744 | percent_diff : 5.07237
MATCH FOUND -> Model LN : 4191826| LocationNumber : 480440 | percent_diff : 0.45199
MATCH FOUND -> Model LN : 4191826| LocationNumber : 375085 | percent_diff : 2.24491
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1570342 | percent_diff : -4.65880
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420026 | percent_diff : 1.75152
MATCH FOUND -> Model LN : 4191826| LocationNumber : 674775 | percent_diff : 7.15105
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4654420 | percent_diff : -8.19525
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530644 | percent_diff : -0.97061
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3551027 | percent_diff : -6.65187
MATCH FOUND -> Model LN : 4191826| LocationNumber : 444380 | percent_diff : -7.77742
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390529 | percent_diff : -9.20740
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1030160 | percent_diff : 2.74335
MATCH FOUND -> Model LN : 4191826| LocationNumber : 630744 | percent_diff : 5.16854
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382075 | percent_diff : 3.81227
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1721469 | percent_diff : 3.76086
MATCH FOUND -> Model LN : 4191826| LocationNumber : 450470 | percent_diff : 4.20072
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1660520 | percent_diff : -3.17934
MATCH FOUND -> Model LN : 4191826| LocationNumber : 480008 | percent_diff : -7.17887
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382011 | percent_diff : -8.06091
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2152280 | percent_diff : -3.69017
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165516 | percent_diff : -7.00488
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4061910 | percent_diff : 3.97405
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1764660 | percent_diff : 7.80717
MATCH FOUND -> Model LN : 4191826| LocationNumber : 371550 | percent_diff : 9.02198
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4081010 | percent_diff : -9.60050
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530720 | percent_diff : 2.69075
MATCH FOUND -> Model LN : 4191826| LocationNumber : 448350 | percent_diff : 8.73556
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4360800 | percent_diff : -0.60500
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1775922 | percent_diff : -1.69753
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4504736 | percent_diff : -0.81350
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4003700 | percent_diff : 6.54461
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1765035 | percent_diff : 2.26860
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165436 | percent_diff : 1.90756
MATCH FOUND -> Model LN : 4191826| LocationNumber : 80780 | percent_diff : -7.25143
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051200 | percent_diff : 4.71207
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1790270 | percent_diff : 2.25806
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051800 | percent_diff : 4.28111
MATCH FOUND -> Model LN : 4191826| LocationNumber : 571606 | percent_diff : -9.17552
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4290350 | percent_diff : 3.18265
MATCH FOUND -> Model LN : 4191826| LocationNumber : 123520 | percent_diff : -4.43108
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2138178 | percent_diff : 9.28568
MATCH FOUND -> Model LN : 4191826| LocationNumber : 442310 | percent_diff : 8.93624
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4216500 | percent_diff : 9.77319
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4024790 | percent_diff : 6.60773
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531915 | percent_diff : -3.24916
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4066442 | percent_diff : 0.62762
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4013660 | percent_diff : -6.02225
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4570595 | percent_diff : -2.66590
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1731871 | percent_diff : -2.17814
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4023600 | percent_diff : -8.90088
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4023850 | percent_diff : 4.89470
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3144800 | percent_diff : 5.86186
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1691288 | percent_diff : 5.52954
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4403466 | percent_diff : -0.07651
MATCH FOUND -> Model LN : 4191826| LocationNumber : 90169 | percent_diff : -1.67898
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1763366 | percent_diff : -0.62538
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1600425 | percent_diff : -0.07275
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390740 | percent_diff : -3.36757
MATCH FOUND -> Model LN : 4191826| LocationNumber : 722160 | percent_diff : 8.77698
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740522 | percent_diff : 9.56906
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1751219 | percent_diff : -8.61451
MATCH FOUND -> Model LN : 4191826| LocationNumber : 411960 | percent_diff : -5.50173
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360685 | percent_diff : 5.96566
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4640670 | percent_diff : -8.69295
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1650630 | percent_diff : 2.61148
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4164850 | percent_diff : -6.96842
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390818 | percent_diff : 3.25377
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2020830 | percent_diff : -6.69849
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1792593 | percent_diff : 0.89378
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4670810 | percent_diff : -8.23649
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4052170 | percent_diff : 6.74859
MATCH FOUND -> Model LN : 4191826| LocationNumber : 512630 | percent_diff : -9.02824
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2193101 | percent_diff : -0.19756
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1660360 | percent_diff : 5.26760
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4076630 | percent_diff : 7.19002
MATCH FOUND -> Model LN : 4191826| LocationNumber : 24060 | percent_diff : -0.14752
MATCH FOUND -> Model LN : 4191826| LocationNumber : 411690 | percent_diff : -1.96260
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4071720 | percent_diff : 5.35356
MATCH FOUND -> Model LN : 4191826| LocationNumber : 331270 | percent_diff : 6.41811
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4002350 | percent_diff : -8.31653
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466340 | percent_diff : -1.60574
MATCH FOUND -> Model LN : 4191826| LocationNumber : 50870 | percent_diff : -3.62990
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3414780 | percent_diff : -8.06574
MATCH FOUND -> Model LN : 4191826| LocationNumber : 370020 | percent_diff : -9.98390
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562800 | percent_diff : 5.23188
MATCH FOUND -> Model LN : 4191826| LocationNumber : 465765 | percent_diff : 6.49720
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4064420 | percent_diff : 4.59800
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382051 | percent_diff : -7.39010
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4162865 | percent_diff : -4.32557
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4082290 | percent_diff : 7.12516
MATCH FOUND -> Model LN : 4191826| LocationNumber : 411180 | percent_diff : 3.44421
MATCH FOUND -> Model LN : 4191826| LocationNumber : 467090 | percent_diff : -6.80619
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447655 | percent_diff : -4.43800
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532450 | percent_diff : -8.00834
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5332330 | percent_diff : 4.67111
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1501090 | percent_diff : -6.50204
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2090262 | percent_diff : -1.86708
MATCH FOUND -> Model LN : 4191826| LocationNumber : 730908 | percent_diff : 2.66922
MATCH FOUND -> Model LN : 4191826| LocationNumber : 472220 | percent_diff : -8.50500
MATCH FOUND -> Model LN : 4191826| LocationNumber : 821736 | percent_diff : -4.74883
MATCH FOUND -> Model LN : 4191826| LocationNumber : 327140 | percent_diff : -1.82886
MATCH FOUND -> Model LN : 4191826| LocationNumber : 387610 | percent_diff : -8.18275
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2170859 | percent_diff : 3.10286
MATCH FOUND -> Model LN : 4191826| LocationNumber : 25590 | percent_diff : 4.60137
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4148865 | percent_diff : -3.54382
MATCH FOUND -> Model LN : 4191826| LocationNumber : 441020 | percent_diff : 4.93884
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447593 | percent_diff : 7.49792
MATCH FOUND -> Model LN : 4191826| LocationNumber : 385105 | percent_diff : 7.09221
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1610909 | percent_diff : 6.64486
MATCH FOUND -> Model LN : 4191826| LocationNumber : 605260 | percent_diff : -0.66872
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740423 | percent_diff : 1.11449
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1741428 | percent_diff : 1.19247
MATCH FOUND -> Model LN : 4191826| LocationNumber : 410400 | percent_diff : 7.37054
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1640470 | percent_diff : 3.27304
MATCH FOUND -> Model LN : 4191826| LocationNumber : 916090 | percent_diff : 4.55981
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4292340 | percent_diff : -3.44515
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1642400 | percent_diff : 9.18271
MATCH FOUND -> Model LN : 4191826| LocationNumber : 388725 | percent_diff : -0.36366
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400205 | percent_diff : 1.09393
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1951100 | percent_diff : 9.37252
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2120297 | percent_diff : -1.00291
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3455490 | percent_diff : -0.22452
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533205 | percent_diff : 0.43939
MATCH FOUND -> Model LN : 4191826| LocationNumber : 120098 | percent_diff : -0.25325
MATCH FOUND -> Model LN : 4191826| LocationNumber : 440750 | percent_diff : -8.48846
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1630350 | percent_diff : 6.65031
MATCH FOUND -> Model LN : 4191826| LocationNumber : 20500 | percent_diff : -5.97726
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530810 | percent_diff : 5.66205
MATCH FOUND -> Model LN : 4191826| LocationNumber : 363710 | percent_diff : -1.44919
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382570 | percent_diff : -2.31352
MATCH FOUND -> Model LN : 4191826| LocationNumber : 373045 | percent_diff : 9.83379
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4256960 | percent_diff : -7.58951
MATCH FOUND -> Model LN : 4191826| LocationNumber : 471470 | percent_diff : -5.97293
MATCH FOUND -> Model LN : 4191826| LocationNumber : 460990 | percent_diff : -7.26853
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1651550 | percent_diff : -2.33294
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4262214 | percent_diff : -0.72982
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532550 | percent_diff : 3.67979
MATCH FOUND -> Model LN : 4191826| LocationNumber : 33894 | percent_diff : -5.58021
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4706310 | percent_diff : 5.61786
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382007 | percent_diff : -9.78675
MATCH FOUND -> Model LN : 4191826| LocationNumber : 460090 | percent_diff : -3.92571
MATCH FOUND -> Model LN : 4191826| LocationNumber : 925500 | percent_diff : -8.94576
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1911973 | percent_diff : -9.85105
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400200 | percent_diff : 6.88437
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3055310 | percent_diff : -2.07726
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1711042 | percent_diff : -1.58071
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3410310 | percent_diff : -8.81700
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4062640 | percent_diff : -3.97212
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3411420 | percent_diff : 9.57100
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2197090 | percent_diff : 5.65783
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4346750 | percent_diff : -6.93716
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1731874 | percent_diff : 8.74692
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1591001 | percent_diff : 4.44691
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400922 | percent_diff : 5.60512
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530930 | percent_diff : -7.57088
MATCH FOUND -> Model LN : 4191826| LocationNumber : 480915 | percent_diff : 3.59001
MATCH FOUND -> Model LN : 4191826| LocationNumber : 781110 | percent_diff : -7.04896
MATCH FOUND -> Model LN : 4191826| LocationNumber : 94165 | percent_diff : 4.71608
MATCH FOUND -> Model LN : 4191826| LocationNumber : 137960 | percent_diff : -9.65592
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580500 | percent_diff : 8.13624
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464440 | percent_diff : -2.71800
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464760 | percent_diff : 4.29508
MATCH FOUND -> Model LN : 4191826| LocationNumber : 470662 | percent_diff : 8.80792
MATCH FOUND -> Model LN : 4191826| LocationNumber : 446390 | percent_diff : 0.26863
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2196008 | percent_diff : 8.81544
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1931036 | percent_diff : -5.44455
MATCH FOUND -> Model LN : 4191826| LocationNumber : 694010 | percent_diff : 3.15669
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1811750 | percent_diff : -6.30351
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390148 | percent_diff : 0.64396
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1780584 | percent_diff : 4.53336
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1792015 | percent_diff : -9.06920
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2070325 | percent_diff : -3.18700
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5333172 | percent_diff : -3.80673
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051270 | percent_diff : 7.68407
MATCH FOUND -> Model LN : 4191826| LocationNumber : 582535 | percent_diff : 0.79347
MATCH FOUND -> Model LN : 4191826| LocationNumber : 385270 | percent_diff : 4.06459
MATCH FOUND -> Model LN : 4191826| LocationNumber : 375485 | percent_diff : -0.08240
MATCH FOUND -> Model LN : 4191826| LocationNumber : 640772 | percent_diff : 3.35500
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4023990 | percent_diff : 0.64306
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1522977 | percent_diff : -1.08619
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4091300 | percent_diff : 9.87177
MATCH FOUND -> Model LN : 4191826| LocationNumber : 389715 | percent_diff : -2.88073
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1961292 | percent_diff : 4.19046
MATCH FOUND -> Model LN : 4191826| LocationNumber : 446060 | percent_diff : -7.16279
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1751422 | percent_diff : 8.29440
MATCH FOUND -> Model LN : 4191826| LocationNumber : 370325 | percent_diff : -6.60428
MATCH FOUND -> Model LN : 4191826| LocationNumber : 455120 | percent_diff : 4.21509
MATCH FOUND -> Model LN : 4191826| LocationNumber : 70650 | percent_diff : 7.31324
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533040 | percent_diff : 2.51196
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4164045 | percent_diff : -3.11474
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1522720 | percent_diff : -1.33582
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1750705 | percent_diff : -5.20878
MATCH FOUND -> Model LN : 4191826| LocationNumber : 33240 | percent_diff : -9.14484
MATCH FOUND -> Model LN : 4191826| LocationNumber : 181032 | percent_diff : 2.53871
MATCH FOUND -> Model LN : 4191826| LocationNumber : 450230 | percent_diff : -6.86934
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3362890 | percent_diff : -9.47980
MATCH FOUND -> Model LN : 4191826| LocationNumber : 993340 | percent_diff : -2.49857
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580955 | percent_diff : -6.02631
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466640 | percent_diff : 5.47484
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4287410 | percent_diff : -1.12075
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400530 | percent_diff : -4.56709
MATCH FOUND -> Model LN : 4191826| LocationNumber : 801670 | percent_diff : 9.22338
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3454960 | percent_diff : 3.02991
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3411690 | percent_diff : 6.18261
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3410730 | percent_diff : -9.01370
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531365 | percent_diff : 6.58200
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532960 | percent_diff : -9.13694
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1750647 | percent_diff : -0.87564
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420650 | percent_diff : 0.62713
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1561050 | percent_diff : -5.34922
MATCH FOUND -> Model LN : 4191826| LocationNumber : 195565 | percent_diff : 2.92825
MATCH FOUND -> Model LN : 4191826| LocationNumber : 381400 | percent_diff : 9.14808
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420112 | percent_diff : 2.25828
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530745 | percent_diff : 4.29467
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2100628 | percent_diff : 2.78251
MATCH FOUND -> Model LN : 4191826| LocationNumber : 361375 | percent_diff : -1.38589
MATCH FOUND -> Model LN : 4191826| LocationNumber : 690678 | percent_diff : -2.36032
MATCH FOUND -> Model LN : 4191826| LocationNumber : 281740 | percent_diff : 7.37919
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1530698 | percent_diff : 7.10314
MATCH FOUND -> Model LN : 4191826| LocationNumber : 371399 | percent_diff : -4.86194
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400315 | percent_diff : -1.48129
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464030 | percent_diff : -5.49858
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3361030 | percent_diff : 4.21795
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3230220 | percent_diff : 6.28583
MATCH FOUND -> Model LN : 4191826| LocationNumber : 472980 | percent_diff : 5.90941
MATCH FOUND -> Model LN : 4191826| LocationNumber : 675025 | percent_diff : -1.82922
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4711917 | percent_diff : -9.61548
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3451030 | percent_diff : -8.53386
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4014460 | percent_diff : 1.58453
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240220 | percent_diff : -7.35029
MATCH FOUND -> Model LN : 4191826| LocationNumber : 385180 | percent_diff : -6.40155
MATCH FOUND -> Model LN : 4191826| LocationNumber : 676180 | percent_diff : -9.01336
MATCH FOUND -> Model LN : 4191826| LocationNumber : 387090 | percent_diff : -1.77628
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1711060 | percent_diff : 0.41430
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530755 | percent_diff : 5.60017
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360625 | percent_diff : 8.81650
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4001240 | percent_diff : -9.35234
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1930883 | percent_diff : 6.57125
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531100 | percent_diff : -4.34316
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1763369 | percent_diff : -6.64752
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2170667 | percent_diff : -6.24623
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4001900 | percent_diff : -7.10228
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1532840 | percent_diff : -2.95515
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431307 | percent_diff : 4.17502
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165230 | percent_diff : -8.74591
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420910 | percent_diff : -1.46734
MATCH FOUND -> Model LN : 4191826| LocationNumber : 146270 | percent_diff : -7.48285
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2091920 | percent_diff : -4.73409
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4366925 | percent_diff : -1.15534
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1650270 | percent_diff : 0.53272
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4081790 | percent_diff : -5.61399
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400050 | percent_diff : -1.72922
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400720 | percent_diff : -5.62756
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580160 | percent_diff : -3.39740
MATCH FOUND -> Model LN : 4191826| LocationNumber : 742780 | percent_diff : -0.11154
MATCH FOUND -> Model LN : 4191826| LocationNumber : 445915 | percent_diff : -5.63086
MATCH FOUND -> Model LN : 4191826| LocationNumber : 471410 | percent_diff : -5.55868
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561840 | percent_diff : -8.92613
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533035 | percent_diff : -1.94260
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532760 | percent_diff : 0.44337
MATCH FOUND -> Model LN : 4191826| LocationNumber : 440392 | percent_diff : 7.12631
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1930769 | percent_diff : -8.26972
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4023834 | percent_diff : -2.72718
MATCH FOUND -> Model LN : 4191826| LocationNumber : 363085 | percent_diff : -8.64523
MATCH FOUND -> Model LN : 4191826| LocationNumber : 363357 | percent_diff : 1.23816
MATCH FOUND -> Model LN : 4191826| LocationNumber : 93243 | percent_diff : -8.52836
MATCH FOUND -> Model LN : 4191826| LocationNumber : 450890 | percent_diff : 7.33475
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447180 | percent_diff : 6.33591
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3453430 | percent_diff : 0.75467
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533245 | percent_diff : -5.33407
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464650 | percent_diff : -0.84482
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4092630 | percent_diff : 6.38463
MATCH FOUND -> Model LN : 4191826| LocationNumber : 252992 | percent_diff : -9.69508
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4094460 | percent_diff : -6.73847
MATCH FOUND -> Model LN : 4191826| LocationNumber : 471080 | percent_diff : 0.83842
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1980760 | percent_diff : 9.00047
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450760 | percent_diff : -3.13023
MATCH FOUND -> Model LN : 4191826| LocationNumber : 376965 | percent_diff : 6.14439
MATCH FOUND -> Model LN : 4191826| LocationNumber : 448765 | percent_diff : 0.70668
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4580585 | percent_diff : -9.61286
MATCH FOUND -> Model LN : 4191826| LocationNumber : 474020 | percent_diff : -0.67355
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4321490 | percent_diff : 5.96835
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4582520 | percent_diff : 8.25503
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447950 | percent_diff : 2.22318
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2193100 | percent_diff : 6.11284
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240680 | percent_diff : 2.59350
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4062360 | percent_diff : -3.90870
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4306290 | percent_diff : -3.60407
MATCH FOUND -> Model LN : 4191826| LocationNumber : 380740 | percent_diff : -0.82972
MATCH FOUND -> Model LN : 4191826| LocationNumber : 446620 | percent_diff : -1.15546
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3315170 | percent_diff : 2.06882
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4740245 | percent_diff : 3.36136
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360845 | percent_diff : 7.86548
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4348960 | percent_diff : -0.31590
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1750032 | percent_diff : 0.54629
MATCH FOUND -> Model LN : 4191826| LocationNumber : 370055 | percent_diff : -9.20758
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4012490 | percent_diff : -2.16160
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740867 | percent_diff : -3.82008
MATCH FOUND -> Model LN : 4191826| LocationNumber : 373645 | percent_diff : -8.27799
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4112270 | percent_diff : -5.64852
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2046277 | percent_diff : -4.88542
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4024860 | percent_diff : 1.43920
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461980 | percent_diff : 9.31740
MATCH FOUND -> Model LN : 4191826| LocationNumber : 552040 | percent_diff : 9.27791
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1931076 | percent_diff : 4.98549
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165446 | percent_diff : -1.20237
MATCH FOUND -> Model LN : 4191826| LocationNumber : 373320 | percent_diff : -2.49780
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1800890 | percent_diff : 9.82493
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400705 | percent_diff : 1.05699
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3415530 | percent_diff : -7.08845
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3033570 | percent_diff : -1.36578
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3454839 | percent_diff : 1.42582
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461080 | percent_diff : 8.39723
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4063490 | percent_diff : -5.61992
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3551028 | percent_diff : -4.36235
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3453670 | percent_diff : -4.84603
MATCH FOUND -> Model LN : 4191826| LocationNumber : 102050 | percent_diff : -4.76506
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242850 | percent_diff : 3.85966
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240620 | percent_diff : -2.37748
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4021360 | percent_diff : -1.25145
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1600531 | percent_diff : -6.77775
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447607 | percent_diff : -0.36266
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4061160 | percent_diff : -0.03813
MATCH FOUND -> Model LN : 4191826| LocationNumber : 55460 | percent_diff : -9.11728
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1741122 | percent_diff : -2.28062
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4430530 | percent_diff : -0.37429
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3034712 | percent_diff : 8.05212
MATCH FOUND -> Model LN : 4191826| LocationNumber : 440620 | percent_diff : 6.81743
MATCH FOUND -> Model LN : 4191826| LocationNumber : 467730 | percent_diff : -5.62004
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466700 | percent_diff : 2.79201
MATCH FOUND -> Model LN : 4191826| LocationNumber : 671650 | percent_diff : 2.59823
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451460 | percent_diff : -4.89534
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3363670 | percent_diff : 2.32204
MATCH FOUND -> Model LN : 4191826| LocationNumber : 384640 | percent_diff : 9.27640
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3453580 | percent_diff : -1.96402
MATCH FOUND -> Model LN : 4191826| LocationNumber : 121640 | percent_diff : 7.38133
MATCH FOUND -> Model LN : 4191826| LocationNumber : 195260 | percent_diff : 6.75671
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4091940 | percent_diff : 9.16487
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4074040 | percent_diff : -6.77621
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740428 | percent_diff : 5.53870
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3203220 | percent_diff : 7.44310
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532605 | percent_diff : 9.86058
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531514 | percent_diff : -1.05721
MATCH FOUND -> Model LN : 4191826| LocationNumber : 467765 | percent_diff : 0.82410
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3362920 | percent_diff : 2.62643
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1511480 | percent_diff : 6.56725
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165444 | percent_diff : -6.22345
MATCH FOUND -> Model LN : 4191826| LocationNumber : 451610 | percent_diff : -4.12164
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1761325 | percent_diff : 4.68309
MATCH FOUND -> Model LN : 4191826| LocationNumber : 950520 | percent_diff : -7.70609
MATCH FOUND -> Model LN : 4191826| LocationNumber : 361465 | percent_diff : 8.04660
MATCH FOUND -> Model LN : 4191826| LocationNumber : 372370 | percent_diff : 0.91104
MATCH FOUND -> Model LN : 4191826| LocationNumber : 94210 | percent_diff : 4.89507
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4165725 | percent_diff : -3.40415
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3453740 | percent_diff : -7.05513
MATCH FOUND -> Model LN : 4191826| LocationNumber : 381969 | percent_diff : 0.29162
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1671330 | percent_diff : -8.92552
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533210 | percent_diff : -0.47398
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461331 | percent_diff : -6.93940
MATCH FOUND -> Model LN : 4191826| LocationNumber : 443510 | percent_diff : 4.63497
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1750423 | percent_diff : -1.36849
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464980 | percent_diff : 9.91127
MATCH FOUND -> Model LN : 4191826| LocationNumber : 378485 | percent_diff : 3.55778
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400056 | percent_diff : -3.48338
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532920 | percent_diff : 7.02679
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4148825 | percent_diff : -1.84164
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4070320 | percent_diff : 5.04236
MATCH FOUND -> Model LN : 4191826| LocationNumber : 449420 | percent_diff : -5.30168
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3452380 | percent_diff : -6.27517
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4013170 | percent_diff : 3.92287
MATCH FOUND -> Model LN : 4191826| LocationNumber : 386950 | percent_diff : -3.31995
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3362680 | percent_diff : -1.06094
MATCH FOUND -> Model LN : 4191826| LocationNumber : 551580 | percent_diff : -2.19984
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2152182 | percent_diff : -0.86597
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4432380 | percent_diff : -1.43813
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1763363 | percent_diff : 8.01398
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2100047 | percent_diff : -8.45691
MATCH FOUND -> Model LN : 4191826| LocationNumber : 441140 | percent_diff : -0.56064
MATCH FOUND -> Model LN : 4191826| LocationNumber : 446570 | percent_diff : 7.16769
MATCH FOUND -> Model LN : 4191826| LocationNumber : 661520 | percent_diff : -5.65565
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4052055 | percent_diff : 1.14476
MATCH FOUND -> Model LN : 4191826| LocationNumber : 442100 | percent_diff : -3.68598
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1910411 | percent_diff : -8.73699
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4283335 | percent_diff : -2.94439
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4023845 | percent_diff : 0.53230
MATCH FOUND -> Model LN : 4191826| LocationNumber : 475910 | percent_diff : -1.83582
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4432200 | percent_diff : -6.92419
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5333510 | percent_diff : 7.99557
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420009 | percent_diff : -8.32411
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3454930 | percent_diff : -8.86929
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1731020 | percent_diff : -1.08266
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4570563 | percent_diff : 1.97837
MATCH FOUND -> Model LN : 4191826| LocationNumber : 480179 | percent_diff : -7.62093
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450670 | percent_diff : 9.41923
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1661175 | percent_diff : -4.44824
MATCH FOUND -> Model LN : 4191826| LocationNumber : 841331 | percent_diff : 5.49165
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4256320 | percent_diff : -2.73136
MATCH FOUND -> Model LN : 4191826| LocationNumber : 463630 | percent_diff : 9.52446
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4060510 | percent_diff : 2.29459
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4076290 | percent_diff : 6.04164
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1620422 | percent_diff : 9.77421
MATCH FOUND -> Model LN : 4191826| LocationNumber : 450410 | percent_diff : -9.29942
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4080550 | percent_diff : -1.55852
MATCH FOUND -> Model LN : 4191826| LocationNumber : 385870 | percent_diff : -4.61365
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2173110 | percent_diff : -4.63133
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4430308 | percent_diff : 0.37898
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3414360 | percent_diff : -4.88409
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4672120 | percent_diff : -1.66058
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1901360 | percent_diff : 4.72612
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240670 | percent_diff : 8.13909
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4706044 | percent_diff : 5.12482
MATCH FOUND -> Model LN : 4191826| LocationNumber : 90162 | percent_diff : -6.45548
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1764348 | percent_diff : 4.84450
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1500060 | percent_diff : 6.98285
MATCH FOUND -> Model LN : 4191826| LocationNumber : 180596 | percent_diff : -9.65096
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1590604 | percent_diff : 9.71769
MATCH FOUND -> Model LN : 4191826| LocationNumber : 20840 | percent_diff : 0.12675
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1711433 | percent_diff : -1.74073
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4081800 | percent_diff : 0.99642
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4491280 | percent_diff : -0.56941
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1812785 | percent_diff : -7.89651
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1570430 | percent_diff : -6.35942
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1692158 | percent_diff : 3.62009
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531200 | percent_diff : -5.32622
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533240 | percent_diff : 7.75289
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4070220 | percent_diff : -0.80115
MATCH FOUND -> Model LN : 4191826| LocationNumber : 190170 | percent_diff : -4.14886
MATCH FOUND -> Model LN : 4191826| LocationNumber : 640780 | percent_diff : -5.22381
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1763353 | percent_diff : 9.83868
MATCH FOUND -> Model LN : 4191826| LocationNumber : 110057 | percent_diff : 3.82113
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4156450 | percent_diff : 8.79402
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1600601 | percent_diff : -7.26880
MATCH FOUND -> Model LN : 4191826| LocationNumber : 472340 | percent_diff : -1.71895
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1741860 | percent_diff : 1.40508
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431490 | percent_diff : -2.62748
MATCH FOUND -> Model LN : 4191826| LocationNumber : 512135 | percent_diff : 1.51130
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4531495 | percent_diff : -2.40164
MATCH FOUND -> Model LN : 4191826| LocationNumber : 582240 | percent_diff : -5.52888
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1531123 | percent_diff : -6.77311
MATCH FOUND -> Model LN : 4191826| LocationNumber : 412620 | percent_diff : 6.25669
MATCH FOUND -> Model LN : 4191826| LocationNumber : 172730 | percent_diff : 9.69014
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400371 | percent_diff : 7.73274
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562420 | percent_diff : -1.03557
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4061070 | percent_diff : 7.24753
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4654660 | percent_diff : -6.47363
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3451360 | percent_diff : 9.76007
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382600 | percent_diff : -9.31537
MATCH FOUND -> Model LN : 4191826| LocationNumber : 640445 | percent_diff : 7.86944
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2196066 | percent_diff : -4.76172
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3412675 | percent_diff : -7.29589
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4020480 | percent_diff : -2.38960
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1530172 | percent_diff : 4.23430
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4706386 | percent_diff : 5.94048
MATCH FOUND -> Model LN : 4191826| LocationNumber : 372685 | percent_diff : 9.18044
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1501150 | percent_diff : 4.29035
MATCH FOUND -> Model LN : 4191826| LocationNumber : 360710 | percent_diff : 7.78495
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2021614 | percent_diff : 9.17656
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4430210 | percent_diff : -5.44286
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3032532 | percent_diff : 0.23590
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1792395 | percent_diff : -2.89756
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4051080 | percent_diff : 9.07739
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4024670 | percent_diff : -9.41602
MATCH FOUND -> Model LN : 4191826| LocationNumber : 464620 | percent_diff : 6.34043
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4093400 | percent_diff : 8.62149
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1640577 | percent_diff : -2.97720
MATCH FOUND -> Model LN : 4191826| LocationNumber : 171142 | percent_diff : -5.50428
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4473880 | percent_diff : -7.79586
MATCH FOUND -> Model LN : 4191826| LocationNumber : 363235 | percent_diff : 3.33653
MATCH FOUND -> Model LN : 4191826| LocationNumber : 90497 | percent_diff : 8.37495
MATCH FOUND -> Model LN : 4191826| LocationNumber : 155110 | percent_diff : 8.66189
MATCH FOUND -> Model LN : 4191826| LocationNumber : 732100 | percent_diff : 8.14479
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4533338 | percent_diff : 2.32257
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1722070 | percent_diff : 5.18315
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562470 | percent_diff : 1.63990
MATCH FOUND -> Model LN : 4191826| LocationNumber : 465120 | percent_diff : 7.77642
MATCH FOUND -> Model LN : 4191826| LocationNumber : 388630 | percent_diff : -5.36416
MATCH FOUND -> Model LN : 4191826| LocationNumber : 378740 | percent_diff : 2.19498
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1512405 | percent_diff : 7.32858
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2193052 | percent_diff : 8.69938
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562100 | percent_diff : 8.15089
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2041241 | percent_diff : 5.42872
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240300 | percent_diff : -9.49048
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1590885 | percent_diff : -2.56716
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4014040 | percent_diff : 5.78777
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4365950 | percent_diff : 9.12331
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4170850 | percent_diff : -5.46895
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1534220 | percent_diff : -8.83122
MATCH FOUND -> Model LN : 4191826| LocationNumber : 430480 | percent_diff : -5.11238
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1601125 | percent_diff : -0.24526
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242690 | percent_diff : 6.84498
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1591018 | percent_diff : -3.70260
MATCH FOUND -> Model LN : 4191826| LocationNumber : 537440 | percent_diff : -0.07578
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420021 | percent_diff : 8.01882
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1671350 | percent_diff : -3.83481
MATCH FOUND -> Model LN : 4191826| LocationNumber : 641748 | percent_diff : 9.90233
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1501532 | percent_diff : 7.40053
MATCH FOUND -> Model LN : 4191826| LocationNumber : 400065 | percent_diff : -2.69621
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3072264 | percent_diff : -7.45176
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2137060 | percent_diff : -5.62665
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1540270 | percent_diff : -7.21598
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562460 | percent_diff : 5.17213
MATCH FOUND -> Model LN : 4191826| LocationNumber : 445700 | percent_diff : -3.80852
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530385 | percent_diff : 6.01465
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530860 | percent_diff : 6.80562
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2000452 | percent_diff : 4.55656
MATCH FOUND -> Model LN : 4191826| LocationNumber : 20520 | percent_diff : 3.76483
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2090275 | percent_diff : 7.50021
MATCH FOUND -> Model LN : 4191826| LocationNumber : 120112 | percent_diff : -0.90295
MATCH FOUND -> Model LN : 4191826| LocationNumber : 5600150 | percent_diff : 2.03711
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447020 | percent_diff : 6.29221
MATCH FOUND -> Model LN : 4191826| LocationNumber : 443000 | percent_diff : -7.89629
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1711422 | percent_diff : 5.09299
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4010810 | percent_diff : 0.48957
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2193175 | percent_diff : -5.28568
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4562820 | percent_diff : 1.87321
MATCH FOUND -> Model LN : 4191826| LocationNumber : 375375 | percent_diff : -8.51176
MATCH FOUND -> Model LN : 4191826| LocationNumber : 377525 | percent_diff : -5.57727
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4200580 | percent_diff : 0.20284
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4081795 | percent_diff : -6.30478
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530620 | percent_diff : 1.39805
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1905473 | percent_diff : -0.99753
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2203201 | percent_diff : -6.19299
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4740015 | percent_diff : -0.80056
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4570490 | percent_diff : 6.57108
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3450430 | percent_diff : 4.06935
MATCH FOUND -> Model LN : 4191826| LocationNumber : 461620 | percent_diff : -4.97252
MATCH FOUND -> Model LN : 4191826| LocationNumber : 386610 | percent_diff : 6.26708
MATCH FOUND -> Model LN : 4191826| LocationNumber : 453980 | percent_diff : -2.12212
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4415035 | percent_diff : -8.63580
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4195178 | percent_diff : -3.36368
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4561119 | percent_diff : 0.50847
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420158 | percent_diff : 8.08681
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3044410 | percent_diff : 9.20566
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1500810 | percent_diff : -3.96847
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4671047 | percent_diff : -1.61614
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390743 | percent_diff : -0.28122
MATCH FOUND -> Model LN : 4191826| LocationNumber : 453071 | percent_diff : -7.42154
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4061320 | percent_diff : -5.39878
MATCH FOUND -> Model LN : 4191826| LocationNumber : 385720 | percent_diff : 0.85625
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4025230 | percent_diff : -3.94760
MATCH FOUND -> Model LN : 4191826| LocationNumber : 844080 | percent_diff : -9.44654
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242810 | percent_diff : 4.15479
MATCH FOUND -> Model LN : 4191826| LocationNumber : 51420 | percent_diff : -9.60254
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1000790 | percent_diff : -5.10436
MATCH FOUND -> Model LN : 4191826| LocationNumber : 101486 | percent_diff : 3.77426
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1763924 | percent_diff : -0.43378
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4021530 | percent_diff : 8.83275
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530355 | percent_diff : 3.27071
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4432370 | percent_diff : -3.96054
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4240310 | percent_diff : 1.17979
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2150115 | percent_diff : -5.05395
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382507 | percent_diff : -0.58648
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1711240 | percent_diff : -7.97453
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1620415 | percent_diff : -1.22511
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1731888 | percent_diff : -7.40323
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1801900 | percent_diff : -7.96923
MATCH FOUND -> Model LN : 4191826| LocationNumber : 465940 | percent_diff : -7.03626
MATCH FOUND -> Model LN : 4191826| LocationNumber : 101910 | percent_diff : 8.77877
MATCH FOUND -> Model LN : 4191826| LocationNumber : 412920 | percent_diff : -9.25555
MATCH FOUND -> Model LN : 4191826| LocationNumber : 420110 | percent_diff : -2.14054
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4162980 | percent_diff : -6.00278
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1740424 | percent_diff : 0.35666
MATCH FOUND -> Model LN : 4191826| LocationNumber : 901990 | percent_diff : 0.30088
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3361695 | percent_diff : 7.53777
MATCH FOUND -> Model LN : 4191826| LocationNumber : 382925 | percent_diff : -8.38645
MATCH FOUND -> Model LN : 4191826| LocationNumber : 581596 | percent_diff : 9.10723
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4000450 | percent_diff : -8.19519
MATCH FOUND -> Model LN : 4191826| LocationNumber : 172972 | percent_diff : -1.80862
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1711478 | percent_diff : -8.24087
MATCH FOUND -> Model LN : 4191826| LocationNumber : 25955 | percent_diff : 0.99529
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4149480 | percent_diff : 8.77709
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1710240 | percent_diff : 5.93286
MATCH FOUND -> Model LN : 4191826| LocationNumber : 950518 | percent_diff : -9.59271
MATCH FOUND -> Model LN : 4191826| LocationNumber : 251460 | percent_diff : 2.07132
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4081360 | percent_diff : -3.08118
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431120 | percent_diff : -4.40301
MATCH FOUND -> Model LN : 4191826| LocationNumber : 3060590 | percent_diff : -0.80512
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4200655 | percent_diff : 1.89252
MATCH FOUND -> Model LN : 4191826| LocationNumber : 387220 | percent_diff : -5.75385
MATCH FOUND -> Model LN : 4191826| LocationNumber : 450920 | percent_diff : -3.44052
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1553460 | percent_diff : 1.39392
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4242170 | percent_diff : 6.19903
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4096040 | percent_diff : -0.86840
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4010180 | percent_diff : 4.27561
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1534983 | percent_diff : -2.13390
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2197072 | percent_diff : -2.62993
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1600878 | percent_diff : -1.44509
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4021560 | percent_diff : 8.34302
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4196480 | percent_diff : -5.48394
MATCH FOUND -> Model LN : 4191826| LocationNumber : 2020920 | percent_diff : -2.91382
MATCH FOUND -> Model LN : 4191826| LocationNumber : 466350 | percent_diff : 1.09394
MATCH FOUND -> Model LN : 4191826| LocationNumber : 454340 | percent_diff : 2.91759
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1721250 | percent_diff : 4.82098
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4432190 | percent_diff : -8.45207
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4403384 | percent_diff : -8.84270
MATCH FOUND -> Model LN : 4191826| LocationNumber : 33210 | percent_diff : -7.12975
MATCH FOUND -> Model LN : 4191826| LocationNumber : 441980 | percent_diff : 6.25152
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1780145 | percent_diff : -6.37982
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4532398 | percent_diff : -5.74679
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1905472 | percent_diff : 5.77933
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530870 | percent_diff : -5.76217
MATCH FOUND -> Model LN : 4191826| LocationNumber : 390301 | percent_diff : 2.53914
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4093960 | percent_diff : 4.90168
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4002370 | percent_diff : -8.32152
MATCH FOUND -> Model LN : 4191826| LocationNumber : 801448 | percent_diff : 0.43768
MATCH FOUND -> Model LN : 4191826| LocationNumber : 372805 | percent_diff : -7.08019
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1911404 | percent_diff : -9.40076
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1611297 | percent_diff : 0.29394
MATCH FOUND -> Model LN : 4191826| LocationNumber : 1671365 | percent_diff : -4.28487
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4530640 | percent_diff : -9.71703
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4431610 | percent_diff : 1.83938
MATCH FOUND -> Model LN : 4191826| LocationNumber : 447980 | percent_diff : -8.29710
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4164870 | percent_diff : -1.68856
MATCH FOUND -> Model LN : 4191826| LocationNumber : 4412750 | percent_diff : -5.02617