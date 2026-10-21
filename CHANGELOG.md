# Changelog

One release is one state of `docker-compose.yml`: the server image, the modules in `modules/`, the web tools and the entry page. Releases are tagged by date (`2026.10.18`; a second release on the same day is `2026.10.18.1`), and each tag has a GitHub Release with the section below.

To upgrade to any release:

```bash
git pull
docker compose pull
docker compose up -d --remove-orphans
```

## Unreleased

Web tools `1.1.0` · entry `1.3.0`

### Improved

- **OLAP Client: a new pivot table.** Drill down and up from a member, expand or collapse all, and a busy state while a query runs. Columns keep their width while you scroll and can be resized; arrow keys move between cells, and a cell menu copies values or rows. The table can be downloaded as CSV.
- **Entry page:** AI agents connect over Streamable HTTP at `/emondrian/mcp` (SSE stays at `/emondrian/mcp/sse` for older clients), and the evaluation key is requested at [emondrian.com/license](https://emondrian.com/license).

### Fixed

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
