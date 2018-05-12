USE MDM
--SET NOCOUNT ON
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

-- Get all the LocationNumbers, iterate over them
DECLARE @Model_LocationNumber VARCHAR(50) 
DECLARE @LocationNumber VARCHAR(50) 
DECLARE @percent_diff DECIMAL(18,5)


DECLARE cursor_models CURSOR FOR  
SELECT LocationNumber FROM #data_summary WHERE LocationNumber IN ('4191826','70220','303099','1751219','1522548','226760','1630115','1530057')
GROUP BY LocationNumber

-- Get the Model another cursor here... dang... b/c we can have multiple models
--SELECT @Model_LocationNumber = 4191826
--SELECT * INTO #model FROM #data_summary WHERE LocationNumber = @Model_LocationNumber

OPEN cursor_models  
FETCH NEXT FROM cursor_models INTO @Model_LocationNumber   
WHILE @@FETCH_STATUS = 0   
BEGIN   
    IF OBJECT_ID('tempdb..#model') IS NOT NULL DROP TABLE #model
    SELECT * INTO #model FROM #data_summary WHERE LocationNumber = @Model_LocationNumber
	
	DECLARE cursor_meters CURSOR FOR  
    SELECT LocationNumber FROM #data_summary GROUP BY LocationNumber

    OPEN cursor_meters   
    FETCH NEXT FROM cursor_meters INTO @LocationNumber   
    WHILE @@FETCH_STATUS = 0   
    BEGIN    
        -- Compare model and this location
        SELECT   
		      #model.hhmm model_hhmm
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
            INSERT INTO   MDM.dbo.Simularities_Results_All 
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
	FETCH NEXT FROM cursor_models INTO @Model_LocationNumber 
END
CLOSE cursor_models   
DEALLOCATE cursor_models


--SET NOCOUNT OFF

/*review  20minutes run time... 
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
         WHERE LocationNumber = 1751219) AS t
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


/****** Script for SelectTopNRows command from SSMS  ******/
SELECT ModelLocationNumber, COUNT(*)
  FROM [MDM].[dbo].[Simularities_Results_All]
GROUP BY ModelLocationNumber


