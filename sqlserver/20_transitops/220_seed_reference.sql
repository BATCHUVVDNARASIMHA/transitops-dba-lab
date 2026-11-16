/*
    220_seed_reference.sql

    Reference and master data. Everything is synthetic and generated with modular
    arithmetic instead of random functions, so every build produces identical data.
    Names, employee details and contact details are invented; e-mail addresses use the
    reserved .example domain and phone numbers use the reserved 555-01xx range.
*/
SET NOCOUNT ON;
USE TransitOps;
GO

INSERT ref.Mode (ModeId, ModeCode, ModeName)
VALUES (1, 'RAIL', 'Heavy Rail'),
       (2, 'BUS',  'Bus'),
       (3, 'TRAM', 'Streetcar');

INSERT ref.Garage (GarageId, GarageCode, GarageName)
VALUES (1, 'NORTH', 'North Bus Garage'),
       (2, 'SOUTH', 'South Bus Garage'),
       (3, 'EAST',  'East Bus and Streetcar Garage'),
       (4, 'YARD',  'Central Rail Yard');

INSERT fare.FareProduct (FareProductId, ProductCode, ProductName, Price)
VALUES (1, 'SINGLE',   'Single Trip',              2.50),
       (2, 'DAY',      'Day Pass',                 9.00),
       (3, 'WEEK',     '7-Day Pass',              21.00),
       (4, 'MONTH',    '30-Day Pass',             95.00),
       (5, 'REDUCED',  'Reduced Fare Single Trip', 1.00),
       (6, 'TRANSFER', 'Free Transfer',            0.00);
GO

-- Routes: 4 rail lines, 34 bus routes, 2 streetcar lines.
INSERT ref.Route (RouteId, RouteCode, RouteName, ModeId)
SELECT x.RouteId,
       CASE WHEN x.RouteId <= 4  THEN 'L' + CAST(x.RouteId AS varchar(10))
            WHEN x.RouteId <= 38 THEN CAST(96 + x.RouteId AS varchar(10))
            ELSE 'S' + CAST(x.RouteId - 38 AS varchar(10)) END,
       CASE WHEN x.RouteId <= 4  THEN CHOOSE(x.RouteId, 'North-South Line', 'Northeast Line', 'East-West Line', 'Crosstown Line')
            WHEN x.RouteId <= 38 THEN 'Route ' + CAST(96 + x.RouteId AS varchar(10)) + ' '
                                      + CHOOSE(1 + (x.RouteId % 10), 'Main Street', 'Riverside', 'University', 'Lakeshore', 'Industrial Park',
                                               'Midtown', 'Stadium', 'Hospital District', 'Airport Road', 'Outer Loop')
            ELSE CHOOSE(x.RouteId - 38, 'Downtown Streetcar', 'Market Streetcar') END,
       CASE WHEN x.RouteId <= 4 THEN 1 WHEN x.RouteId <= 38 THEN 2 ELSE 3 END
FROM (SELECT CAST(t.n AS int) AS RouteId FROM dbo.fn_Numbers(40) AS t) AS x;
GO

-- Stops: 38 rail stations (StopId 1 to 38) and 562 street stops (39 to 600).
-- StopId 1 is the central hub and carries about a third of all taps: the skew is
-- deliberate, it is what makes the parameter sniffing lab reproducible.
WITH Names (Id, Name) AS (
    SELECT v.Id, v.Name
    FROM (VALUES ( 1, 'Central'),   ( 2, 'Union'),     ( 3, 'Riverside'), ( 4, 'Lakeview'),  ( 5, 'Midtown'),
                 ( 6, 'Northgate'), ( 7, 'Southgate'), ( 8, 'Eastgate'),  ( 9, 'Westgate'),  (10, 'University'),
                 (11, 'Stadium'),   (12, 'Airport'),   (13, 'Civic Center'), (14, 'Market'), (15, 'Harbor'),
                 (16, 'Garden'),    (17, 'Hillcrest'), (18, 'Brookside'), (19, 'Fairview'),  (20, 'Oakwood'),
                 (21, 'Maple'),     (22, 'Cedar'),     (23, 'Elm'),       (24, 'Pine'),      (25, 'Walnut'),
                 (26, 'Chestnut'),  (27, 'Magnolia'),  (28, 'Dogwood'),   (29, 'Sycamore'),  (30, 'Willow'),
                 (31, 'Highland'),  (32, 'Parkside'),  (33, 'Summit'),    (34, 'Valley'),    (35, 'Meadow'),
                 (36, 'Prairie'),   (37, 'Canal'),     (38, 'Foundry'),   (39, 'Depot'),     (40, 'Exchange')) AS v (Id, Name)
)
INSERT ref.Stop (StopId, StopCode, StopName, IsStation, Latitude, Longitude)
SELECT x.StopId,
       CASE WHEN x.StopId <= 38 THEN 'STN' ELSE 'STP' END + RIGHT('0000' + CAST(x.StopId AS varchar(10)), 4),
       CASE WHEN x.StopId <= 38 THEN a.Name + ' Station'
            ELSE a.Name + ' St at ' + b.Name + ' Ave' END,
       CASE WHEN x.StopId <= 38 THEN 1 ELSE 0 END,
       CAST(33.600000 + ((x.StopId * 37) % 300) / 1000.0 AS decimal(9,6)),
       CAST(-84.550000 + ((x.StopId * 53) % 350) / 1000.0 AS decimal(9,6))
FROM (SELECT CAST(t.n AS int) AS StopId FROM dbo.fn_Numbers(600) AS t) AS x
JOIN Names AS a ON a.Id = 1 + ((x.StopId - 1) % 40)
JOIN Names AS b ON b.Id = 1 + ((x.StopId * 7) % 40);
GO

-- Stop sequences. Rail lines share the hub station; each street stop belongs to one route.
INSERT ref.RouteStop (RouteId, StopSequence, StopId)
SELECT r.RouteId,
       CAST(ROW_NUMBER() OVER (PARTITION BY r.RouteId ORDER BY s.StopId) AS smallint),
       s.StopId
FROM ref.Route AS r
JOIN ref.Stop AS s
  ON (r.ModeId = 1  AND s.IsStation = 1 AND (s.StopId = 1 OR s.StopId % 4 = r.RouteId % 4))
  OR (r.ModeId <> 1 AND s.IsStation = 0 AND s.StopId % 36 = r.RouteId % 36);
GO

-- Vehicles: 150 rail cars, 480 buses, 20 streetcars.
INSERT ops.Vehicle (VehicleId, FleetNumber, ModeId, GarageId, ModelYear, Status, InServiceDate)
SELECT x.VehicleId,
       CASE WHEN x.VehicleId <= 150 THEN 'RC' WHEN x.VehicleId <= 630 THEN 'BU' ELSE 'SC' END
           + RIGHT('0000' + CAST(x.VehicleId AS varchar(10)), 4),
       CASE WHEN x.VehicleId <= 150 THEN 1 WHEN x.VehicleId <= 630 THEN 2 ELSE 3 END,
       CASE WHEN x.VehicleId <= 150 THEN 4 WHEN x.VehicleId <= 630 THEN 1 + (x.VehicleId % 3) ELSE 3 END,
       2008 + ((x.VehicleId * 7) % 17),
       CASE WHEN x.VehicleId % 25 = 0 THEN 'RETIRED' WHEN x.VehicleId % 9 = 0 THEN 'IN_SHOP' ELSE 'ACTIVE' END,
       DATEFROMPARTS(2008 + ((x.VehicleId * 7) % 17), 1 + (x.VehicleId % 12), 1 + (x.VehicleId % 28))
FROM (SELECT CAST(t.n AS int) AS VehicleId FROM dbo.fn_Numbers(650) AS t) AS x;
GO

-- Operators: 1,200 invented employees.
WITH FirstNames (Id, Name) AS (
    SELECT v.Id, v.Name
    FROM (VALUES ( 1, 'James'),  ( 2, 'Maria'),   ( 3, 'Robert'),  ( 4, 'Linda'),  ( 5, 'Michael'), ( 6, 'Patricia'),
                 ( 7, 'David'),  ( 8, 'Angela'),  ( 9, 'William'), (10, 'Denise'), (11, 'Carlos'),  (12, 'Keisha'),
                 (13, 'Thomas'), (14, 'Yolanda'), (15, 'Andre'),   (16, 'Susan'),  (17, 'Kevin'),   (18, 'Monica'),
                 (19, 'Brian'),  (20, 'Tamika'),  (21, 'Jose'),    (22, 'Karen'),  (23, 'Marcus'),  (24, 'Nicole'),
                 (25, 'Steven'), (26, 'Latoya'),  (27, 'Daniel'),  (28, 'Rosa'),   (29, 'Anthony'), (30, 'Cheryl')) AS v (Id, Name)
),
LastNames (Id, Name) AS (
    SELECT v.Id, v.Name
    FROM (VALUES ( 1, 'Smith'),    ( 2, 'Johnson'),  ( 3, 'Williams'), ( 4, 'Brown'),   ( 5, 'Jones'),    ( 6, 'Garcia'),
                 ( 7, 'Miller'),   ( 8, 'Davis'),    ( 9, 'Martinez'), (10, 'Wilson'),  (11, 'Anderson'), (12, 'Thomas'),
                 (13, 'Taylor'),   (14, 'Moore'),    (15, 'Jackson'),  (16, 'Martin'),  (17, 'Lee'),      (18, 'Perez'),
                 (19, 'Thompson'), (20, 'White'),    (21, 'Harris'),   (22, 'Clark'),   (23, 'Lewis'),    (24, 'Robinson'),
                 (25, 'Walker'),   (26, 'Young'),    (27, 'Allen'),    (28, 'King'),    (29, 'Wright'),   (30, 'Scott'),
                 (31, 'Green'),    (32, 'Baker'),    (33, 'Adams'),    (34, 'Nelson'),  (35, 'Hill'),     (36, 'Campbell'),
                 (37, 'Mitchell'), (38, 'Roberts'),  (39, 'Carter'),   (40, 'Phillips')) AS v (Id, Name)
)
INSERT ops.Operator (OperatorId, EmployeeNumber, FirstName, LastName, Email, Phone, LicenseNumber, HireDate, GarageId)
SELECT x.OperatorId,
       'E' + CAST(100000 + x.OperatorId AS char(6)),
       f.Name,
       l.Name,
       LOWER(f.Name + '.' + l.Name) + CAST(x.OperatorId AS varchar(10)) + '@transitops.example',
       '555-01' + RIGHT('00' + CAST(x.OperatorId % 100 AS varchar(10)), 2),
       'CDL' + RIGHT('000000000' + CAST((CAST(x.OperatorId AS bigint) * 7919) % 1000000000 AS varchar(10)), 9),
       DATEADD(DAY, -((x.OperatorId * 13) % 6000), CAST('2026-04-30' AS date)),
       1 + (x.OperatorId % 4)
FROM (SELECT CAST(t.n AS int) AS OperatorId FROM dbo.fn_Numbers(1200) AS t) AS x
JOIN FirstNames AS f ON f.Id = 1 + (x.OperatorId % 30)
JOIN LastNames  AS l ON l.Id = 1 + ((x.OperatorId * 7) % 40);
GO

-- Fare cards: 120,000.
INSERT fare.Card (CardId, CardSerial, IssuedDate, Status, Balance)
SELECT x.CardId,
       'TC' + RIGHT('00000000000000' + CAST(10000000000000 + CAST(x.CardId AS bigint) * 7919 AS varchar(20)), 14),
       DATEADD(DAY, -(x.CardId % 1500), CAST('2026-04-30' AS date)),
       CASE WHEN x.CardId % 50 = 0 THEN 'BLOCKED' WHEN x.CardId % 33 = 0 THEN 'EXPIRED' ELSE 'ACTIVE' END,
       CAST(((x.CardId * 37) % 6000) / 100.0 AS decimal(8,2))
FROM (SELECT CAST(t.n AS int) AS CardId FROM dbo.fn_Numbers(120000) AS t) AS x;
GO

SELECT 'ref.Route' AS TableName, COUNT(*) AS RowsLoaded FROM ref.Route
UNION ALL SELECT 'ref.Stop', COUNT(*) FROM ref.Stop
UNION ALL SELECT 'ref.RouteStop', COUNT(*) FROM ref.RouteStop
UNION ALL SELECT 'ops.Vehicle', COUNT(*) FROM ops.Vehicle
UNION ALL SELECT 'ops.Operator', COUNT(*) FROM ops.Operator
UNION ALL SELECT 'fare.Card', COUNT(*) FROM fare.Card;
GO
