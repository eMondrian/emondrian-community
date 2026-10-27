# Changelog

One release is one state of `docker-compose.yml`: the server image, the modules in `modules/`, the web tools and the entry page. Releases are tagged by date (`2026.10.18`; a second release on the same day is `2026.10.18.1`), and each tag has a GitHub Release with the section below.

To upgrade to any release:

```bash
git pull
docker compose pull
docker compose up -d --remove-orphans
```

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
