# Changelog

One release is one state of `docker-compose.yml`: the server image, the modules in `modules/`, the web tools and the entry page. Releases are tagged by date (`2026.10.18`; a second release on the same day is `2026.10.18.1`), and each tag has a GitHub Release with the section below.

To upgrade to any release:

```bash
git pull
docker compose pull
docker compose up -d --remove-orphans
```

## 2026.11.09.2

Server `10.0.85` · modules `0.0.0.102` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

Modules `0.0.0.102` (were `0.0.0.101`). The server image, the web tools, the Dashboard, the entry page and `docker-compose.yml` are unchanged.

- `ENABLE_SERVICE_DASHBOARD=false` in `.env` now turns off the MCP dashboard tools as well as the `/dashboard/` page. Before, an agent could still create dashboards through MCP with the page off.
- `delete_catalog` no longer deletes a catalog when it cannot check whether dashboards read it, for example when the key with `DASHBOARD` has expired or the Dashboard does not answer. It says why; `ignoreDashboards=true` deletes anyway. Before, such a delete went ahead and could leave dashboards reading a catalog that was gone.
- The MCP dashboard tools no longer describe dashboards as part of eMondrian Enterprise.

## 2026.11.09.1

Server `10.0.85` · modules `0.0.0.101` · OLAP Client `1.2.3` · Dashboard `0.1.3` · entry `1.3.2`

OLAP Client `1.2.3` (was `1.2.0`) and the Dashboard application, new in Community. The server, the modules, the Schema Editor and Catalog Editor (`1.1.0`) and the entry page are unchanged.

### Dashboards

- The `dashboard` service serves dashboards at `/dashboard/`, built by an AI agent through the MCP dashboard tools. Until now those tools answered that dashboards were part of eMondrian Enterprise.
- It needs a licence key including `DASHBOARD` in `modules/`. Dashboards are kept in the `dashboard_data` volume.
- `ENABLE_SERVICE_DASHBOARD=false` in `.env` turns the route off. Like the rest of Community, the dashboards have no users or access control.

### OLAP Client

- **Pivot tables with two or more hierarchies on rows.** Every row hierarchy after the first was drawn inside the data cells, shifted by the width of the ones before it, and row headers did not stay in place when scrolling sideways.
- **Members with an empty name** (a `NULL` or empty key) read "(blank)" instead of their unique name, such as `[Origin Airport.Origin State].[]`, in the table and in the copied or downloaded one.
- **Long row groups.** Scrolled into a group, the top visible row repeats the group's member, so it never scrolls out of sight.

## 2026.11.09

Server `10.0.85` · modules `0.0.0.101` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.101` (were `0.0.0.100`) and `schema/Foodmart.xml`. The server image, the web tools, the entry page and `docker-compose.yml` are unchanged.

### Schemas: the classic form is obsolete

- New schemas use the attribute model (`<DimensionAttribute>`). A classic dimension, one with no `<DimensionAttribute>`, still loads and answers MDX, but `validate_schema`, `save_schema` and `save_catalog` name it in a warning. `get_cube_authoring_guide` says the same.
- DAX and Power BI need the attribute model. A DAX query naming a classic dimension's column now says so, instead of "Hierarchy … have not found".
- `schema/Foodmart.xml` no longer has `Store_my`, an unused classic dimension over a table the database does not have.

### Connecting a new database with an agent

- `save_catalog` without `xml`, for a catalog with no schema file yet, writes an empty schema and registers the catalog, so `describe_source` and `validate_source_sql` work before the cube is written. It used to refuse.
- Right after `save_catalog` or `save_schema`, `get_schema`, `validate_schema`, `add_time_measures` and `list_catalogs` see the new schema. For a few seconds they used to answer "Schema resource not found", or read the previous version.
- `validate_schema` with `checkSource`:
  - looks tables up in the catalog's own database by their exact name. On MySQL and MariaDB it searched every database on the server and also tried other letter cases, so a table could pass because another database had one of that name;
  - a name in the wrong case is an error that gives the database's spelling;
  - checks the columns of attribute-model dimensions against the dimension's own table.
- On MySQL and MariaDB, `describe_source`'s `schema` is the database name; it used to list every database's tables.
- An error that quotes a table with its database name (MariaDB: `Table 'db.table' doesn't exist`) keeps the name instead of showing `'?'`.

## 2026.11.08.3

Server `10.0.85` · modules `0.0.0.100` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.100` (were `0.0.0.99`). The server image, the web tools, the entry page and `docker-compose.yml` are unchanged.

### Deleting a catalog through MCP

- **`delete_catalog`** deletes a catalog in one call: its entry in `datasources.xml`, its schema file, its `<Catalog> (synthetic)` catalog with the generated schemas, and the generated `syn_*` databases. No restart is needed; the catalog is gone for the next request, and a session that still had it open fails on its next query.
- The deletion is permanent: nothing is kept aside. Keep your schemas in git if you may want them back; synthetic data can be generated again.
- A schema file that another catalog also uses is kept, and the answer says which catalog uses it. Given `<Catalog> (synthetic)`, only the synthetic catalog and its data are deleted.
- With the Enterprise Dashboard application, a catalog that dashboards read is not deleted unless `ignoreDashboards` is true, and the dashboards are named in the answer; they are never changed.
- **`delete_schema`** deletes a schema file under `/WEB-INF/schema/` that no catalog uses any more.
- Both need the same rights as `save_catalog`, and a server started with `-Demondrian.mcp.readOnly=true` does not offer them.

## 2026.11.08.2

Server `10.0.85` · modules `0.0.0.99` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.99` (were `0.0.0.98`). The server image, the web tools, the entry page and `docker-compose.yml` are unchanged.

### Licence keys

- **No licence change needs a restart.** Until now a key that had passed once was used until the server restarted, so an expiry or a replaced key waited for a restart. Now, for each module, the server uses the first key in `modules/` that is valid, includes the module and is within its dates. A new key works from the next request; an extension or a key placed beside the current one takes over when the current one expires, without a gap; an expiry takes effect at the expiry time; a deleted key, or one with fewer modules, stops counting within an hour.
- Old keys can stay in `modules/`: an expired or wrong-module key is skipped.
- The "No eMondrian licence found" message now ends with "A free 30-day evaluation key is available at https://emondrian.com/license"; it no longer lists the modules the evaluation key includes.

## 2026.11.08.1

Server `10.0.85` · modules `0.0.0.98` (now with `synthetic`) · web tools `1.2.0` · entry `1.3.2`

The server image, the web tools and the entry page are unchanged. `modules/` now includes the synthetic module, and `docker-compose.yml` gains a one-time `synthetic-init` service.

### Synthetic catalogs

- **The synthetic module is part of Community**, under a licence key that includes `SYNTHETIC`, as DAX and MCP need theirs. New evaluation keys include it; a key issued earlier keeps the modules it was issued with, so get a new one to try it.
- A synthetic catalog, `<Catalog> (synthetic)`, has a real catalog's cubes, dimensions, measures and roles over generated data. An agent builds it with `generate_synthetic_catalog` and follows it with `synthetic_catalog_status`. Nothing is generated on its own.
- Generated data goes to the bundled ClickHouse, into `syn_*` databases, through two users that cannot read the real data there. `setup.sh` (and `windows-setup.ps1`) creates their passwords in `.env` as `EMONDRIAN_SYN_WRITER_PASSWORD` and `EMONDRIAN_SYN_READER_PASSWORD`. **Upgrading:** run `./setup.sh` once, or set both in `.env` yourself, then `docker compose up -d`. Without them the server starts as before and synthetic catalogs cannot be generated.
- If you load a database of your own into the bundled ClickHouse, add a `REVOKE` for it to `clickhouse/init-scripts/init-synthetic.sh`.

### What an agent sees: an option, off by default

Agents read real data, as before, unless you turn the option on. Nothing in `datasources.xml` or `.env.example` turns it on.

- **On, for one catalog:** add `agentAccess="synthetic-only"` to its `<Catalog>` in `datasources.xml` (or call `generate_synthetic_catalog` with `"restrictSource": true`). It applies from the next MCP call; restart the eMondrian service if your editor replaced the file.
- **On, for every catalog:** add `JAVA_TOOL_OPTIONS=-Demondrian.mcp.agentAccess=synthetic-only` to `.env` and run `docker compose up -d --force-recreate eMondrian`.
- **Off:** remove the attribute (or set `agentAccess="real"`), or remove the `JAVA_TOOL_OPTIONS` line and recreate the service. Where both are set, the stricter one applies.

When it is on, the structure tools work on the real catalog and the tools that return values or member names refuse and point to `<Catalog> (synthetic)`, as described in 2026.11.08. The README's "Synthetic catalogs" section has the details.

## 2026.11.08

Server `10.0.85` · modules `0.0.0.98` · web tools `1.2.0` · entry `1.3.2`

Server `10.0.85` (engine `9.3.0-emondrian.85`, was `10.0.84`) and modules `0.0.0.98` (were `0.0.0.97`). The web tools and the entry page are unchanged. `docker-compose.yml` gains an optional `env_file: .env` and two directories, `drivers/` and `share/`, which `setup.sh` creates; run `mkdir -p drivers share` if you upgrade without it.

### Connecting a new database through MCP

- **Credentials in `.env`.** Put a database's user and password or token in `.env` as `EMONDRIAN_SRC_<NAME>_USER`, `_PASSWORD` or `_TOKEN` and restart the server. A connect string names them as `${env:EMONDRIAN_SRC_SALES_PASSWORD}`, and the value is read only when a connection opens. `save_catalog` refuses a connect string with a password or token written into it, and one that names a variable that is not set. MCP answers, errors and `read_logs` included, show `***` instead of these values. New tool `list_source_credentials` lists the variables and whether each is set, never their values.
- **JDBC drivers at run time.** New tool `install_driver` adds a driver jar from Maven Central coordinates, an https URL on an allowed host (`emondrian.drivers.allowedHosts`, Maven Central by default) or the share. The jar's SHA-256 is required, and for Maven it must also match the repository's own checksum. Installed jars are kept in `drivers/` and loaded without a restart, and again at every start. A driver the image already includes (PostgreSQL, ClickHouse, HSQLDB) is refused with the class name to use. `list_drivers` lists what is installed. `install_driver` is not offered on a read-only server.
- **The share.** `share/` is mounted read-only at `/share`. Put a file there and a tool can use it as `share:path/to/file`; `list_shared_files` lists them. Paths that leave the share are refused.
- **The source's structure, not its data.** `describe_source` lists a database's schemas, tables, columns, types and keys; `validate_source_sql` checks a query or an expression without fetching a row; `validate_schema` with `checkSource: true` checks a schema's tables, columns and views against the database. None of them returns rows, row counts, defaults or statistics.

### What an agent sees of a catalog's data

What an agent sees of a catalog's data is a setting. By default an agent reads a catalog's data like any other client. For an agent to see only the schema and synthetic data, set `agentAccess="synthetic-only"` on the `<Catalog>` in `datasources.xml`, or `-Demondrian.mcp.agentAccess=synthetic-only` for every catalog on the server. The server-wide setting is the one to use where a whole server holds real data.

On a synthetic-only catalog the structure tools (`get_schema`, `save_schema`, `validate_schema`, `save_catalog`, `describe_source`, `validate_source_sql`) now work, so an agent can build a cube on a new database. The tools that return values or member names (`execute_query`, `describe_cube`, `get_csdl`, the Power BI report tools, dashboards) refuse and point to `<Catalog> (synthetic)`. `list_catalogs` lists such a catalog with a note. Without synthetic catalogs on the server, the structure tools still work and the data tools still refuse. Excel, Power BI and the web client are not affected.

Limits worth knowing: on a synthetic-only catalog `validate_source_sql` refuses nested queries (subqueries, derived tables, `WITH`) on every database, because a database can evaluate a subquery before the check's row filter and return its values in an error message. On ClickHouse this applies to every catalog. Errors from structure tools on such a catalog keep only quoted text the agent sent itself. `save_catalog` recognises a restricted catalog's database only by the same JDBC address.

### Fixes

- Synthetic catalogs: a cube whose dimensions are classic hierarchies over their own tables (no attribute model) got a two-row fact table with its measures as text, and every query on it failed.

## 2026.11.07.2

Server `10.0.84` · modules `0.0.0.97` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.97` (were `0.0.0.96`). The server image, the web tools and the entry page are unchanged.

### DAX

- **`ASC` and `DESC` in `TOPN` and `SAMPLE`.** `TOPN(10, 'Table', [Measure], DESC)` was a syntax error: the keywords were accepted only after `ORDER BY`. They now work wherever a sort order goes, in any case, and mean the same as the numbers `0` (descending) and `1` (ascending) that Power BI writes.

### Power BI reports from MCP

- `make_visual` describes the order of conditional-formatting rules plainly: list them as Power BI Desktop's Rules dialog shows them, top to bottom.

## 2026.11.07.1

Server `10.0.84` · modules `0.0.0.96` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.96` (were `0.0.0.95`). The server image, the web tools and the entry page are unchanged.

### Power BI reports from MCP

- **Tooltips.** A column or bar chart takes measures in `Tooltips`, shown when a bar is hovered. `sort` can name one of them, which sorts a chart by a measure it does not show.
- **Conditional formatting in tables and matrices.** `conditionalFormatting` colours a measure's background as a gradient from lowest to highest, colours its background or font by rules on the measure itself or on another measure, or adds data bars (tables). List the rules as Power BI Desktop's Rules dialog shows them, top to bottom: where two match, the later one wins.
- **Tooltip pages.** `make_page` with `"tooltip": true` makes a 400 x 300 page that a chart shows on hover, filtered to the hovered bar; the chart names it with `"tooltipPage"`. The page's visuals are placed for that size.

### Known limitations

- Power BI does not offer three of its visuals on a live connection to eMondrian: the new card visual with categories, a slicer on a hierarchy, and small multiples. Power BI itself declines them for this kind of source; the classic card, slicers on a column and separate charts work.

## 2026.11.07

Server `10.0.84` · modules `0.0.0.95` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.84` (was `10.0.74`), modules `0.0.0.95` (were `0.0.0.89`). The web tools and the entry page are unchanged.

### Power BI

- **Selecting a value in a Top N chart.** Clicking a bar in a chart limited to its Top N showed the Top N's total in the other visuals instead of the clicked value's, and prior-year and plan columns were blank for it. The selection is now the clicked value within the Top N, for every measure.
- **Slicer lists follow the other slicers.** A slicer on one attribute listed every value even when a slicer on another attribute of the same dimension was set (every city under a state filter). It now lists only the values that exist together with the selection, as Analysis Services does.
- **Several values selected in a slicer.** Visuals that filter on the slicer's own field failed under a slicer with more than one value selected; they now show the numbers.
- **Top N over two fields** with fewer rows of data than N could return wrong rows; it returns the rows with data, then the rest.
- **Faster pages under slicers.** Cells and Top N filters read under slicers use the cube's aggregate tables where one carries the slicer's columns; a page that took seconds can take a fraction of one. Before, a Top N under slicers could pick an aggregate table it could not join and run for minutes.
- **Filters:** `'T'[C] IN {"a", "b"}`, and `= BLANK()` / `<> BLANK()` on an attribute with empty values.

### DAX for hand-written queries

- New: `SELECTEDVALUE`, `HASONEVALUE`, `REMOVEFILTERS`, `VAR ... RETURN`, `DATEDIFF`, `EOMONTH`, `WEEKDAY`, `ROUNDUP`, `ROUNDDOWN`, `CEILING`, `FLOOR`, `MOD`, `LOG`, `EXACT`, `SUBSTITUTE`, and `SUM`/`AVERAGE`/`MIN`/`MAX`/`COUNT`/`DISTINCTCOUNT` of a column, which answer with the measure to use.
- `REPLACE` replaces by position, as in DAX (it found and replaced text).
- `VALUES` and `COUNTROWS` follow the filters in effect; `CALCULATE` takes OR and IN conditions, `ALL('T')`, `ALL(c1, c2)`, `KEEPFILTERS` and conditions over several columns. `SAMPLE(n, ...)` returns n rows.
- Forms that are not supported give a clear error that quotes the expression, instead of being ignored.

### Excel and MDX

- **`NON EMPTY` in Excel pivots.** With subtotals in a pivot, rows came back grouped in the wrong order. A calculated measure that sets a member of a field on the rows (for example, a measure fixed to one year) lost rows that had values. Both are fixed.
- **`NON EMPTY` with measures that use their own aggregate function** (`aggregatorImplementation`) returned no rows for crossjoins whose combinations had data.
- A cache flush now also clears the cells read under a subselect.

## 2026.11.05.1

Server `10.0.74` · modules `0.0.0.89` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.74` (was `10.0.73`), modules `0.0.0.89` (were `0.0.0.85`). The web tools and the entry page are unchanged.

### Server

- **Power BI filters on attributes with empty values.** Clicking a row or a slicer value in Power BI on an attribute that has empty (NULL) members put an error message in the cells ("Expected value of type STRING; got value '#null'") instead of the numbers. The empty member is now passed over, as any member that does not match.
- **Prior-year and plan columns under Power BI slicers.** A calculated measure that reads another year or another version (prior year, plan) showed the right totals but was empty on every row of a matrix or chart once slicers were set, because its cells were read together with the actual's and under the actual's year. They are now read under their own coordinates, as the same calculation already did with a `WHERE` clause.

### Power BI reports from MCP

- **Single-select slicers.** A slicer with `"singleSelect": true` lets the reader pick one value at a time. It needs a `selection` (one value, or `{"latest": true}`), because Power BI Desktop otherwise selects the first value when the report opens, even one with no data.
- **Totals off.** `"totals": false` turns off a matrix's subtotals and grand totals; `{"rows": false}` or `{"columns": false}` turns off one side. On a table it removes the total row.
- **Cards fit their value.** A card is as wide as its value when the page opens. When the cards do not fit beside the slicers, they get a row of their own, so a long figure such as `1,464,108,407.19` is no longer cut off.
- **Measure folders.** A measure's `displayFolder` now groups it in Power BI's Data pane; `A\B` gives a subfolder.

## 2026.11.05

Server `10.0.73` · modules `0.0.0.85` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.73` (was `10.0.72`), modules `0.0.0.85` (were `0.0.0.84`). The web tools and the entry page are unchanged.

### Server

- **Power BI slicers on a virtual cube.** In a virtual cube, a measure wrapped in `ValidMeasure` failed when a Power BI slicer was set on a dimension its own cube does not have, and the visual showed "Error fetching data". Power BI sends every slicer as a subselect, which now leaves such a measure unrestricted, as the same member in a `WHERE` clause always did. Slicers on dimensions the measure's cube has still filter it.
- **Schema validation of virtual cubes.** `validate_schema` now checks the attributes of `VirtualCube`, `CubeUsage` and `VirtualCubeMeasure`. `ignoreUnrelatedDimensions` on a `VirtualCubeMeasure`, where the server ignores it, gets a warning that says it belongs on `<CubeUsage>`.

### MCP

- The cube authoring guide explains both, in its section on several fact tables.

## 2026.11.04.4

Server `10.0.72` · modules `0.0.0.84` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.84` (were `0.0.0.83`). The server image, the web tools and the entry page are unchanged.

### Power BI

- **A matrix keeps its rows when the cube's default measure is empty.** A matrix with rows and columns kept a row only when the cube's default measure (its first measure) had data, not the measures the matrix shows. On a cube whose first measure is empty for some rows, those rows were dropped, and a matrix could show only its total. The measures in the visual now decide.

## 2026.11.04.3

Server `10.0.72` · modules `0.0.0.83` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.83` (were `0.0.0.82`), `docker-compose.yml` and the setup scripts. The server image, the web tools and the entry page are unchanged.

### MCP

- **Power BI projects get the address Desktop connects to.** `make_project`'s `dataSource` is the XML/A address Power BI Desktop uses to reach this server, which is often another machine than the one eMondrian runs on. Its description now says so and tells the agent to ask you when it does not know the address; an agent used to guess `http://localhost:8080/emondrian/xmla`, and Desktop could not open the project without an edit. Tell the agent the address, e.g. `http://my-server/xmla`, when you ask it for a project.

### Setup

- **A `.env` with only some settings works.** A `.env` holding just `EMONDRIAN_PORT` left the front door without `/xmla`, the tools and MCP (all 404) while the setup script said "ready". Every route is now on unless `.env` turns it off; the setup scripts list the settings `.env` leaves out, and stop with an error when `/xmla` does not answer.

## 2026.11.04.2

Server `10.0.72` · modules `0.0.0.82` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.72` (was `10.0.70`). The modules, web tools and entry page are unchanged.

### Server

- **Clearer messages for mistyped MDX.** `[Store].[Store State].Members()` with parentheses failed with a bare `UnsupportedOperationException`; it now says `No function matches signature '<Level>.Members()'`. A bracket or a quote left open (`[Unit Sales` with no `]`) reached the client as "Unknown Error"; it is now a syntax error that says the bracket or quote is not closed.
- **A no-break space is whitespace.** A query copied from a web page or a document often carries no-break spaces, which were a syntax error. They are now read as ordinary spaces.
- **Quieter start.** The server no longer logs failed registrations for library classes bundled in the MCP module at every start.

## 2026.11.04.1

Server `10.0.70` · modules `0.0.0.82` · web tools `1.2.0` · entry `1.3.2`

Modules `0.0.0.82` (were `0.0.0.81`). The server image, the web tools and the entry page are unchanged. Recommended for anyone using the time measures of 2026.11.04 in Power BI.

### Time intelligence in Power BI

- **A month with no data of its own stays in the table.** In a table of months with a one-year slicer, Power BI keeps a row while any of its measures is not blank. That check read the measures without the slicer's year, so a month with no sales but a year-to-date value (December, in a year whose data ends in November) was missing. It is there again, with its year-to-date, same-period-last-year and rolling values.
- **The total row shows the year.** Power BI computes a table's total over the months it shows, and the time measures took that for a chosen month and were blank. The total row now shows the year's values: year-to-date, same period last year and year-over-year change, with no rolling value. Time measures created with `add_time_measures` before this release keep the old formula; delete them and run the tool again to get the new one.
- **Several years in an MDX `WHERE` set** make the time measures fail with "the coordinate for the '[Time.Year]' hierarchy contains a set", as in Analysis Services. A subselect, which Excel sends for several years, works. The cube authoring guide now says so.

## 2026.11.04

Server `10.0.70` · modules `0.0.0.81` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.70` (was `10.0.63`), modules `0.0.0.81` (were `0.0.0.76`). The web tools and the entry page are unchanged.

### Time intelligence

- **Time measures in the schema.** The cube authoring guide (`get_cube_authoring_guide`) has a new section on year-to-date, quarter-to-date, same period last year, previous year, year-over-year change and rolling three months, written as calculated members. They give the same numbers in Excel, which uses the user hierarchy, and in Power BI, which uses the attribute hierarchies. A distinct count over a year to date is one query over those months, not the sum of the months. Ratios are built from the time measures of their parts, never by aggregating the ratio itself.
- **New MCP tool `add_time_measures`.** It writes those measures for the stored measures you name, with the cube's own hierarchy names. It previews by default and changes the schema only with `save=true`. It is registered with the other write tools, so a server started with `emondrian.mcp.readOnly=true` does not offer it. It needs a time hierarchy with an All member and a month level; a week hierarchy beside it is left out.
- **Power BI: a year chosen in a slicer reaches the time measures.** With one year chosen and months on the visual, year-to-date, same period last year and rolling measures use that year. With several values chosen there is no single period, so the time measures are blank, while plain measures add up over the selection.
- Report-level DAX time functions such as `TOTALYTD` are not supported: Power BI does not offer report measures on this connection. Use the calculated members above.

### Server

- **Filters on the bundled FoodMart database return the right members.** A filter whose condition uses no measure, such as `Filter([Time].[Month].Members, 1 = 0)`, returned every member, and an aggregation over it returned the unfiltered total. The condition is now applied.
- **An empty distinct count is empty.** A distinct count aggregated over an empty set returned `1.2345E-8`, which showed as `0`. The cell is now empty.
- **Time calculations under a slicer.** A calculated member that reaches into another year, such as the same month last year or a rolling window across January, now gets that year under a subselect on the year. The cells on the axes are still restricted to the selection.
- **A numeric key written as `1998.0`** (as Power BI sends it) now matches the member with key `1998` on ClickHouse.
- **Comparing a member's name with text on a numeric key** (`[Time].[Month].CurrentMember.Name = "x"`) is no longer a SQL error.
- **Calculated members with an explicit `MEMBER_ORDINAL`** no longer make the schema fail to load with "Ordinal N is not unique" when other calculated members are added.
- **`validate_schema` warns about out-of-order cube elements.** A `<CalculatedMember>` after a `<DrillThroughAction>` (or any child of a cube out of the declared order) is ignored when the schema is read; the validator now says so.
- **Boolean keys** are read as booleans, not `0`/`1`, so captions are right, filters on them work and Power BI sorts them correctly.
- **Member names returned by the server parse back.** On a dimension whose attribute hierarchy carries the dimension's own name, a unique name returned by the server (from `TopCount`, say) was not found when sent back, and a calculated member defined there could be referred to by one spelling only. Both spellings now work.
- **A measure filter with a custom aggregate function** (`aggregatorImplementation`, such as `uniqExact`) uses that function in the SQL it sends.
- **Parallel queries and cancels** no longer fail now and then with `ConcurrentModificationException`, and ending a session the server no longer has is not logged as an error.
- **Metrics:** the open-connections gauge (`emondrian_connections`) has samples again, and the query metrics carry a `language` label, `MDX` or `DAX`.

### Power BI

- **A model with an attribute named `<X> Key`** no longer collides with the hidden key property of `X`, which made Power BI refuse the model.
- **DAX resolves hierarchies and levels by object.** On a dimension whose attribute hierarchy carries the dimension's own name, totals (`ROLLUP`) failed and columns could return the All member. A level named differently from the attribute it is built on is a column again.
- `make_page` and `make_project` write an empty key as `null`.

## 2026.11.02.1

Server `10.0.63` · modules `0.0.0.76` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.63` (was `10.0.62`), modules `0.0.0.76` (were `0.0.0.74`). The web tools and the entry page are unchanged. Upgrading is recommended for every installation that connects Claude or another current MCP client.

### MCP

- **Claude can connect again.** Since about 21 October 2026, Claude clients (claude.ai, the desktop app, Claude Code) have sent new optional fields in their first `initialize` request. The MCP server rejected them, so every connection failed with HTTP 400 `Unrecognized field "form"` and the connector reported it could not reach the server. The server now ignores fields it does not know, as the protocol intends, so later additions do not break connecting either.

### Server

- **Queries no longer leave engine connections open.** Every MDX or DAX query, and every cancel request, used to leave one internal connection behind until the next full garbage collection, so the open-connections count only ever grew. They are now closed when the request ends.
- **A failed request no longer leaves its session open.** A request sent without a session gets a temporary one, and after an error it stayed open until the idle timeout (`mondrian.server.IdleOrphanSessionTimeout`, one hour by default). It is now closed whether the request succeeds or fails.

## 2026.11.02

Server `10.0.62` · modules `0.0.0.74` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.62` (was `10.0.58`). The modules, web tools and entry page are unchanged.

### Power BI Service

- **Scheduled refresh through the on-premises data gateway works.** Before a refresh, the Service checks the model for changes. It sends a system-table query and asks for the server description, and both answers now match what Analysis Services returns. Refreshes had been failing with `FailedDeserializeSchema`; dashboard tiles now refresh on their own.
- **System-table (DMV) queries** such as `SELECT [LAST_SCHEMA_UPDATE] FROM $SYSTEM.MDSCHEMA_CUBES` return only the selected columns, as a query result. `SELECT *` is accepted, column names are case-insensitive, and an unknown column is an error. `DBSCHEMA_CATALOGS.DATE_MODIFIED` is the time the schema was loaded.
- **The server description** (`DISCOVER_XML_METADATA`) can be read by Microsoft's AMO/TOM client libraries. It reports a real edition and the server mode, and lists the databases.

### Data sources

- **Credentials can come from the environment.** A connect string in `datasources.xml` may contain `${env:EMONDRIAN_*}` placeholders. They are resolved when the connection is made, so the file is served and saved exactly as written, without the secret.

## 2026.10.30

Server `10.0.58` · modules `0.0.0.74` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.58` (was `10.0.57`). The web tools and the entry page are unchanged. Upgrading is recommended for every installation that exposes the MCP endpoint.

### MCP

- **`execute_query` validates its `cube` argument.** It must be the exact name of a cube in the catalog; anything else is refused with the list of the catalog's cubes.
- **Catalog arguments must be strings**, and a tool that requires `catalog` refuses a call without one before doing anything else.

### MCP traffic log

The MCP server now writes every message between it and agents to `logs/mcp-audit.log`, one JSON object per line, both directions:
- the session, the client and its user agent, and the client network;
- the tool, catalog, cube and query;
- the status, error, duration, size and rows.

- **On by default, in `metadata` mode**: no tool arguments or results, but the query text is kept. `full` adds them; `off` turns the log off (`emondrian.mcp.audit`).
- **Client addresses are truncated before writing**: IPv4 to /24, IPv6 to /48, on by default (`emondrian.mcp.audit.truncateIp=false` keeps full addresses).
- **The local file rotates at 50 MB**, and rotated files are deleted after 30 days.
- Secrets and licence file names are redacted, and `read_logs` does not expose the log.

See [MCP traffic log](README.md#mcp-traffic-log) in the README for the settings, the event format and how to ship it to Loki or ELK.

## 2026.10.29

Server `10.0.57` · modules `0.0.0.71` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.57` (was `10.0.51`). The web tools and the entry page are unchanged.

### Power BI Service through the on-premises data gateway

- **The gateway's connection properties are accepted.** `EffectiveUserName`, `Roles` and `CustomData` no longer fail the request. `EffectiveUserName` is **accepted and ignored** unless the connecting account's role is granted impersonation (`mondrian.security.role.<role>.impersonate=allow` in `mondrian.properties`). This edition grants nothing, so every report viewer is served as the gateway's own connection: there is **no per-viewer security**.
- **Rowset schemas declare the `xmlDocument` type**, which the Service's schema check required.
- **XML/A property names are case-insensitive**, and unknown properties are ignored (logged once) instead of failing the request.
- **`mondrian.xmla.providerVersion`** sets the server version reported in `DISCOVER_PROPERTIES` and `DISCOVER_XML_METADATA`. The default is unchanged.

### DAX, as Power BI visuals send it

- A measure referenced as `[Flights]` in a query that also defines a column named "Flights" resolves to the measure (it used to overflow the stack).
- Matrix subtotals: `ROLLUP` uses the All member of the hierarchy the query names, so a matrix on Day of Week or Distance Group renders its totals.
- An attribute hierarchy named after its dimension gets a unique name of its own, so it no longer clashes with the dimension's user hierarchy.
- `SUMMARIZECOLUMNS` with `ROLLUPADDISSUBTOTAL` returns its subtotal rows and flag columns; table constructors `{ … }` and `TREATAS` over them are supported; `ISINSCOPE` is false on subtotal rows.
- A drill-through combined with a "contains" filter on the same column no longer fails.
- A text filter on a column whose key is numeric (Quarter) no longer fails with a type error.
- A Top N visual filter is applied before a table's row limit, so the table shows the top N rows.
- "Show items with no data" (`GENERATEALL`) is supported.
- The field list leaves out measures the caller's role cannot access.
- The OnTime sample shows names, not keys, for Quarter, Month, Day of Week and Distance Group.

### Power BI reports from MCP

- **New visual types for `make_visual`, `make_page` and `make_project`:** gauge, scatter (with Size and Play), stacked area, area, stacked column, 100% stacked column, ribbon, waterfall, funnel, donut and treemap; a line chart takes a second axis (`Y2`).
- **`colors`** sets fixed colours for a chart's legend members or categories; **`averageLine`** draws an average line on a line chart.

### Known limitations

- The new Card visual with Categories is not supported.
- The hierarchy slicer and small multiples are not yet verified.
- No row-level or per-viewer security through the gateway (see above).
- DAX covers what Power BI visuals generate on a live connection; time-intelligence functions are not implemented.
- DAX and the MCP tools need a licence; this repository ships without one. A free 30-day evaluation key is at https://emondrian.com/license: put the `.lic` file into `modules/` next to `docker-compose.yml`; no restart is needed.

## 2026.10.27.4

Server `10.0.51` · modules `0.0.0.64` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (unchanged). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP: `arrange_page` keeps charts wide enough.** Given the page's `catalog` and `cube`, it counts each line and column chart's categories, as `make_page` does, and gives it the width they need. Without them it says that no width was checked; `make_visual`'s result names the call to make.
- **Power BI reports from MCP: charts wrap into a second row** when one row cannot give every chart the width its categories need, for new pages and re-arranged ones alike.

## 2026.10.27.3

Server `10.0.51` · modules `0.0.0.63` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (unchanged). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP: a chart as wide as its categories.** A line or column chart gets 31 px per category on its axis, counted on the server under the page filters and the slicers that filter it, so a line of 30 years is 930 px and shows every year instead of scrolling. The other charts in the row share the rest; when a row cannot fit, the result says which chart is short.
- **Power BI reports from MCP: time in time order.** A column or bar chart on a time dimension's column (Year, Month) sorts by it, so months read 1 to 12; other categories still sort by value, largest first.
- **OnTime schema:** `Time` is declared a time dimension (years, quarters, months), as FoodMart's is. MDX time functions such as `YTD` now work on it. The figures and the Power BI metadata are unchanged.

## 2026.10.27.2

Server `10.0.51` · modules `0.0.0.62` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (unchanged). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP: a tighter top row.** A card with a title no longer repeats the measure name under its value (`"header": true` keeps it). Dropdown slicers are 70 px and cards 90 px instead of 180 px, so the charts below start higher and are taller. A list slicer keeps 180 px.

### Fixed

- **Count measures show zero as 0.** Flights, Cancelled, Diverted, Late Arrivals and Distinct Tail Numbers in OnTime, and Sales Count, Customer Count, Store Sqft and Grocery Sqft in FoodMart, were formatted `#,###`, which shows zero as an empty cell; in Power BI a value axis read ".0M .2M". They are now `#,##0`. The numbers are unchanged.

## 2026.10.27.1

Server `10.0.51` · modules `0.0.0.61` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (unchanged). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP: a slicer no longer filters a chart of its own field.** With the Year slicer on 2025, a line chart of the on-time rate by year still shows every year, so the selection is seen in context; a chart on the whole Time hierarchy counts too. Tables, matrices and cards are still filtered. A visual's `"slicers"` option overrides this: `"filter"` lets every slicer filter it, `"ignore"` lets none. The project shows the same settings in Desktop under Format → Edit interactions.

## 2026.10.27

Server `10.0.51` · modules `0.0.0.60` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.51` (engine 9.3.0-emondrian.51). The web tools and the entry page are unchanged.

### Improved

- **Power BI reports from MCP (`make_visual`, `make_page`, `make_project`) start from better defaults.**
  - A `latest` slicer on Year selects the latest *complete* year: a year still in progress is passed over, and the result says which one (`skippedPartial`). `{"latest": true, "complete": false}` takes it anyway.
  - Cards show the whole number (7,001,619, not 7M); `"displayUnits": "auto"` gives Desktop's default back.
  - Slicers are dropdowns and show their field name once; `"style": "list"` and `"header": true` give the list and the header back.
  - Line charts use the smallest axis font, so every year label is shown in full.
- **OnTime schema:** the `KeyColumn` `type` attribute, which the server ignores, is gone, so loading OnTime logs 13 fewer warnings. The model and its numbers are unchanged.

### New

- **Horizontal bar charts.** `"type": "bar"` writes Power BI's clustered bar chart, with the same fields, sort and Top N filter as `column`.

### Fixed

- **`CASE` with no `WHEN`.** `CASE ELSE 1 END` failed with *Index 1 out of bounds for length 1*; it is now an ordinary "No function matches signature" error.

## 2026.10.26.1

Server `10.0.50` · modules `0.0.0.58` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.50` (engine 9.3.0-emondrian.50). The web tools and the entry page are unchanged.

### New

- **MCP `describe_cube`.** One call lists a cube's dimensions (time dimensions marked), hierarchies with their All and default members, levels with their level type, the row count the schema reports and an optional counted one, a sample member, and the stored and calculated measures. An agent checking a cube it has just written no longer needs access to the server's files.
- **MCP sessions see a saved schema the way XML/A sessions do.** After `save_schema` or `save_catalog`, the session that saved and every new session get the new version; sessions already open keep the version they started with until they end.
- **`save_schema` and `save_catalog` check what they saved.** They load the catalog and open a database connection, and report a failure plainly, saying the file was saved, with a hint for the common causes: a host name with an underscore, which the ClickHouse driver rejects, or a host the server cannot resolve.
- **`validate_schema` checks time dimensions.** Every level of a `TimeDimension`, including the attribute hierarchies it generates, must have a time level type (`TimeUndefined` counts), and no other dimension may have one. The server refused such a schema when loading it, without saying why; the validator now reports it with the fix.
- **MCP `make_project` can default its server address.** `-Demondrian.mcp.publicXmlaUrl=<url>` sets the XML/A URL written into a Power BI project when the agent passes no `dataSource`; without it, `dataSource` stays required.
- **The cube authoring guide** (`get_cube_authoring_guide`) covers measures, time dimensions, shared dimensions and virtual cubes, calculated members, and how MDX names members and levels.

### Fixed

- **MCP:** a tool that hit an internal Java error left the client waiting for an answer that never came; it now returns the error. Passwords in connection errors are masked.

## 2026.10.26

Server `10.0.49` · modules `0.0.0.56` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.49` (engine 9.3.0-emondrian.49). The web tools and the entry page are unchanged.

### New

- **Agent access per catalog.** `<Catalog agentAccess="none">` in `datasources.xml` (an attribute on the element) keeps a catalog away from MCP agents: `list_catalogs` leaves it out and every tool that names it refuses. `-Demondrian.mcp.agentAccess` sets the same rule for the whole server. XML/A clients are not affected.
- **`mondrian.result.evaluationLimit`.** With it set, `mondrian.result.limit` applies to the cells a `NON EMPTY` query returns, not to the size it had before the empty rows and columns were removed; the new property bounds that larger, in-memory size. Unset (the default), nothing changes.

### Fixed

- **Excel pivot filters on large levels.** A filter Excel sends as a subquery with an explicit set of members looked every member up again on each cell request, so a few thousand selected members made a query take minutes ([#6](https://github.com/eMondrian/emondrian-community/issues/6)). Filtering 6 000 tail numbers in OnTime now takes 2 s instead of 8 s, with the same numbers.
- **Cell properties.** A query asking for a cell property the server had no element for (`FONT_NAME`, `FONT_SIZE`, `ACTION_TYPE`, …, as some Excel versions do) failed with *XMLA Execute unparse results error* after it had run. All the standard cell properties are returned now, and unknown ones are ignored.
- **MCP:** the dashboard tools are listed, and answer that the Dashboard application is not available on this server; dashboards are part of eMondrian Enterprise. The synthetic-catalog tools answer that their module is not installed.

## 2026.10.22

Server `10.0.47` · modules `0.0.0.54` · web tools `1.2.0` · entry `1.3.2`

Docker image `emondrian/emondrian:10.0.47` (engine 9.3.0-emondrian.47). OLAP Client `1.2.0`; the Schema Editor and Catalog Editor stay `1.1.0`.

### New

- **Server metrics.** The server exports Prometheus metrics at `/metrics`: active users, open sessions and connections per user and catalog, queries started, finished and failed per cube and user, execution times, result sizes, engine errors by class, and the JVM's own metrics. The front door does not expose the endpoint (it carries user names); scrape it on the Docker network. The [demo repository](https://github.com/eMondrian/emondrian-demo) has a Prometheus and Grafana overlay with a ready *User activity* dashboard.
- **OLAP Client understands eMondrian's MDX.** `x IS EMPTY`, `x IN set`, `x NOT IN set`, `s MATCHES pattern`, `||` for strings, numbers like `1.` and the `BEFORE_AND_AFTER` flag no longer show as syntax errors. The server's own functions (`Cache`, `Percentile`, `Parameter`, `CurrentDateMember`, the extra VBA functions, member properties such as `.Caption`) and its forms of `StrToSet`, `StrToTuple`, `StrToMember`, `Levels` and `NonEmptyCrossJoin` are known to validation, completion and hover.

### Improved

- **OLAP Client warns before the server fails:** a comma between WITH clauses, `CALCULATED MEMBER`, an axis given as an expression, functions in DRILLTHROUGH RETURN, single quotes after `AS`, `TRUE`/`FALSE`, the `TYPED`, `CONSTRAINED` and `RECURSIVE` flags, cell properties the server cannot return, `+` on strings, `CURRENTCUBE`, `@param`, CAST types the server lacks, and a function used as a method or a property (`set.Order(…)`, `member.Children()`).

### Fixed

- **Server:** DRILLTHROUGH from an aggregate member, and `NON EMPTY` over a member's children joins the level's table (engine 9.3.0-emondrian.46).
- **Entry:** the `/dashboard/mcp` route is gone; the only MCP endpoint is `/emondrian/mcp`.

## 2026.10.21.1

Server `10.0.45` · modules `0.0.0.54` · web tools `1.1.1` · entry `1.3.1`

OLAP Client `1.1.1`; the Schema Editor and Catalog Editor stay `1.1.0`.

### Fixed

- **OLAP Client:** expanding a member in the pivot no longer hangs on "Running the query…" when the cube was chosen while the client was still starting.

## 2026.10.21

Server `10.0.45` · modules `0.0.0.54` · web tools `1.1.0` · entry `1.3.1`

Docker image `emondrian/emondrian:10.0.45`, which `latest` now points to.

### Improved

- **Power BI reports built by AI agents** cover more of what Power BI Desktop writes: slicers set to the latest month, display units on data labels, sort and several visual filters, matrices with several Rows or Columns fields (collapsed or expanded), and charts drilled down a hierarchy.
- **OLAP Client: a new pivot table.** Drill down and up from a member, expand or collapse all, and a busy state while a query runs. Columns keep their width while you scroll and can be resized; arrow keys move between cells, and a cell menu copies values or rows. The table can be downloaded as CSV.
- **Entry page:** AI agents connect over Streamable HTTP at `/emondrian/mcp` (SSE stays at `/emondrian/mcp/sse` for older clients), and the evaluation key is requested at [emondrian.com/license](https://emondrian.com/license).

### Fixed

- **Several members in the slicer:** a query with a set in its WHERE clause, such as `{[Airline].[AA], [Airline].[DL]}`, no longer returns empty axes.
- **Power BI cross-highlighting** from a chart with a visual Top N no longer fails the other visuals.
- **Entry after a partial restart:** the entry looks containers up on every request, so `/xmla`, MCP and the tools keep working after `docker compose up -d` recreates some of them.
- **OnTime sample:** On-Time Rate is empty where Flights is empty, instead of showing 100%.

## 2026.10.18

Server `10.0.44` · modules `0.0.0.52` · web tools `1.0.1` · entry `1.2.1`

Docker image `emondrian/emondrian:10.0.44`, which `latest` now points to.

### New

- **Power BI reports built by AI agents.** The MCP tools `make_project`, `make_page`, `make_visual`, `arrange_page` and `validate_report` write a Power BI project (PBIP) with a live connection to your eMondrian model, including sort, Top N, filters and slicer selections. They need a key with DAX and MCP.

### Fixed

- **Power BI matrices with subtotals** render, with the total last, filtered by a slicer to the selected columns only, in about 1 second instead of 36.
- **Ratio grand totals** in Power BI are recomputed instead of summed.
- **Measure format strings** reach Power BI, and named formats (Standard, Currency, …) are expanded.
- **Several visuals opening at once** no longer fail one of them with "Session with id … already exists".

## 2026.10.16.1

Server `10.0.43` · modules `0.0.0.50` · web tools `1.0.1` · entry `1.2.1`

### Improved

- **`get_csdl`** returns the CSDL `<Schema>` element instead of the XML/A row around it.
- **Licence errors** say what to do instead of naming a path inside the container; the file names and reasons are in `logs/mondrian.log`.
- **README:** a Licence keys section. Keep exactly one valid `.lic` file in `modules/`: the server uses the first one that validates.

## 2026.10.16

Server `10.0.43` · modules `0.0.0.49` · web tools `1.0.1` · entry `1.2.1`

### New

- **MCP tool `get_csdl`:** a cube's model as Power BI sees it (CSDL), with the field names a Power BI report has to use. Read-only; needs a key with DAX and MCP.

### Fixed

- A rare race when the MCP servlet shut down while answering a CSDL request.

## 2026.10.14

Server `10.0.43` · modules `0.0.0.48` · web tools `1.0.1` · entry `1.2.1`

### Improved

- **Web tools:** the OLAP Client, Schema Editor, Catalog Editor and entry page use navy tints for quiet text and outlines, as on emondrian.com.

## 2026.10.13

Server `10.0.43` · modules `0.0.0.48` · web tools `1.0` · entry `1.0`

### New

- **MCP over Streamable HTTP** at `/emondrian/mcp` (with or without a trailing slash). HTTP+SSE at `/emondrian/mcp/sse` stays for older clients. Same tools on both.
- **`list_catalogs` names each catalog's cubes,** so an agent writes `FROM [OnTime (attributes)]` instead of guessing.

### Fixed

- **`NON EMPTY` on an attribute-mapped level** (for example `NON EMPTY {Descendants([Time].[2025],[Time].[Month])}` on OnTime) failed on ClickHouse with Code 81.
- **MCP error bodies** no longer contain Java stack traces.

### Removed

- **MCP tools `list-cubes` and `run-mdx-query`.** Use `list_catalogs` and `execute_query`. The `emondrian.mcp.connectString` property is gone from `docker-compose.yml`.

## 2026.10.10

Server `10.0.42` · modules `0.0.0.47` · web tools `1.0` · entry `1.0` · tag `v10.0.42`

Mostly fixes, all of them found while building Power BI reports against a live cube.

### Fixed

- **`TopCount` and `BottomCount` on ClickHouse** returned every member instead of the N asked for.
- **A page with many visuals** failed on a random subset of them, differently on each refresh.
- **A slicer on a column that contains empty values** always failed.
- **A measure whose name starts with `#`** stopped Power BI from loading the model.

### New

- **Read-only MCP.** `-Demondrian.mcp.readOnly=true` leaves the tools that write schemas, register catalogs, read logs or report server properties unregistered. This is how the public demo runs.

## 2026.10.09

Server `10.0.39` · modules `0.0.0.46` · web tools `1.0` · entry `1.0`

### New

- **MCP tool `save_catalog`** registers a catalog in `datasources.xml` and writes its schema file in one call; the catalog is usable without a restart.

### Fixed

- **`run-mdx-query`** returned an object description instead of the query result.
- **Licence keys** are checked for their start date as well as their expiry.

## Earlier

Releases up to server `10.0.39` and web tools `1.0` are described in the [release notes](https://docs.emondrian.com/reference/releases).
