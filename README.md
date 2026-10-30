# eMondrian Community

**eMondrian Community** is the free and open-source (OSS) edition of **eMondrian** — a ROLAP (Relational OLAP) server for multidimensional data analytics.

It provides an analytical layer on top of relational databases, allowing users to define OLAP cubes, execute MDX queries, and build analytical and BI applications using a transparent, SQL-based model.

📝 What's new: [Power BI and AI agents on your own semantic model](https://dev.to/sergeisemenkov/the-new-emondrian-power-bi-and-ai-agents-on-your-own-semantic-model-4nap)

---

## Key Features

- Execute MDX queries on relational databases
- Aggregate caching and query acceleration
- JDBC-based compatibility with multiple SQL databases
- Open and extensible architecture
- Suitable for embedded analytics and lightweight BI use cases

---

## Who Is This For

- BI developers and data engineers working with OLAP-style analytics
- Teams looking for an open-source analytical engine to embed or customize
- Organizations that prefer transparent, relational, and SQL-based analytical models

---

## Prerequisites

- Git
- Internet connection
- Windows 10/11 or a supported Linux distribution
- Administrator / `sudo` rights — needed to install Docker and to start containers
- **Port 80 must be free** — or pick another one. The web front door binds it, so an existing web server (IIS, Apache, nginx) will stop the setup; set `EMONDRIAN_PORT` in `.env` to use a different port instead
- About **2 GB** of free disk space, and roughly **700 MB** of downloads on the first run (container images, plus a ~26 MB sample dataset that expands to ~230 MB on disk)

Docker is installed automatically by the quick-start script if it is not already available.

---

## Quick Start

Clone the repository:

```bash
git clone https://github.com/eMondrian/emondrian-community.git
cd emondrian-community
```

### Linux

```bash
./setup.sh
```

If the script has just installed Docker for you, your user is not in the `docker`
group yet. Log out and back in (or run `newgrp docker`) and start the script again.

### Windows

Run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1
```

If WSL 2 is not installed or needs to be updated, the setup script may require a Windows restart. After restarting Windows, open PowerShell in the project directory and run the same command again:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1
```

The script installs Docker if needed, downloads a sample flight-data set, starts
the containers and loads the data. Expect a few minutes on the first run, most of
it spent downloading. Re-running it is safe — data already imported is skipped.

Once started, open the main page in your browser:

```
http://localhost
```

If port 80 is already taken on your machine, set a different one before running
the script — copy `.env.example` to `.env` and change:

```
EMONDRIAN_PORT=8081
```

Every address below then uses that port, e.g. `http://localhost:8081/xmla`.

---

## Endpoints

After startup, the following endpoints are available:

| Endpoint | What it is |
|---|---|
| `http://localhost` | Main page — links to the tools below |
| `http://localhost/xmla` | **XML/A endpoint** for BI tools and client applications |
| `http://localhost/client/` | Browser OLAP client — explore the sample cubes without installing anything |
| `http://localhost/schema-editor/` | Schema editor — create and edit cubes in the browser |
| `http://localhost/catalog-editor/` | Catalog editor — data sources and catalogs the server publishes |
| `http://localhost/logs/` | Server logs |
| `http://localhost/emondrian/mcp` | **MCP endpoint** for AI agents, streamable HTTP — see below |
| `http://localhost/emondrian/mcp/sse` | The same MCP server over the older HTTP+SSE transport |

The XMLA endpoint can be used to connect BI tools and client applications
such as Power BI, Excel, or custom MDX clients.

Web applications on another origin can call `/xmla` and `/api` from the browser:
the front door answers CORS requests, including the `SOAPAction` header XMLA
clients send. `CORS_ALLOW_ORIGIN` in `.env` sets which origin may do so:

```
CORS_ALLOW_ORIGIN=*                        # default: any origin
CORS_ALLOW_ORIGIN=https://app.example.com  # one origin
CORS_ALLOW_ORIGIN=                         # leave CORS to the eMondrian server
```

Run `docker compose up -d` after changing it.

---

## Connect an AI agent (MCP)

The server speaks the Model Context Protocol, so an AI agent can list cubes, run
MDX or DAX, read the schema and tail the logs. The MCP server is part of the
eMondrian container — there is nothing extra to start.

It is served through the same front door as everything else, on port 80 (or
whatever `EMONDRIAN_PORT` is set to). Both MCP transports are available on the
same server, with the same tools: **streamable HTTP** at
`http://localhost/emondrian/mcp` (with or without the trailing slash), which is
what the current spec defines, and **HTTP+SSE** at
`http://localhost/emondrian/mcp/sse`, which is what older clients point at. To
turn MCP off, set `ENABLE_SERVICE_MCP=false` in `.env` and run
`docker compose up -d`.

Claude Code:

```bash
claude mcp add --transport http emondrian http://localhost/emondrian/mcp
claude mcp add --transport sse  emondrian http://localhost/emondrian/mcp/sse   # older clients
```

There are no authentication headers on either.

The `/emondrian/` prefix is part of the URL and not a typo: on the SSE
transport the server's handshake tells the client to post back to
`/emondrian/mcp/message`, so the client has to reach that path on this origin.

Things to try once connected:

- *"List the catalogs on this server"* → FoodMart and OnTime
- *"Run this MDX on catalog FoodMart: SELECT {[Measures].[Org Salary]} ON 0 FROM [HR]"*
- *"Which Mondrian properties are set on this server?"*

**The MCP tools need a licence key that includes the `MCP` module**, and
`get_csdl` needs `DAX` as well — see [Licence keys](#licence-keys) below. MDX
over XML/A, the browser client and the editors need no key at all.

Ten tools are exposed: `list_catalogs`, `get_schema`, `get_csdl`,
`execute_query`, `validate_schema`, `get_cube_authoring_guide`,
`get_properties`, `save_schema`, `save_catalog` and `read_logs`. The last four
read or **write** server state rather than query data — `save_schema`
overwrites a catalog's schema XML and `save_catalog` edits the catalog
registry. On this edition nothing is authenticated, so treat MCP access as
administrative access.

`get_csdl` returns one cube's model as Power BI sees it — the same CSDL
document Power BI Desktop receives on a live connection, so an agent can write
Power BI report files that name fields the way the model does. It needs a
licence granting `DAX` as well as `MCP`.

### MCP traffic log

Every message between the MCP server and agents is written to
`logs/mcp-audit.log`, one JSON object per line, in both directions: who
connected (session, client name and version, user agent, client network), what
they asked (tool, catalog, cube, the MDX/DAX text) and what came back (status,
error, duration, size, row count). It is on by default; nothing has to be
installed.

- **Client addresses are truncated** before anything is written: IPv4 to /24,
  IPv6 to /48. The full address is never stored.
- **Secrets are redacted**: password-, token- and key-like arguments, `Password=`
  in connect strings, bearer credentials, PEM blocks, licence file names.
- **The log can't be read through MCP**: `read_logs` does not list it.
- **If logging can't keep up, MCP is not slowed down**: events are dropped and
  counted. Once a minute an `audit_stats` line reports `dropped_total`.
- The file rotates at 50 MB, and rotated files are deleted after 30 days.

Settings, as `-D` options added to `JAVA_TOOL_OPTIONS` in `docker-compose.yml`:

| Option | Default | |
|---|---|---|
| `emondrian.mcp.audit` | `metadata` | `off`, `metadata` (no arguments or results; the query text is kept), `full` (arguments and result text too) |
| `emondrian.mcp.audit.maxBody` | `65536` | bytes per body field; longer ones are cut and flagged `<field>_truncated` |
| `emondrian.mcp.audit.truncateIp` | `true` | `false` keeps full client addresses |
| `emondrian.mcp.audit.trustedProxies` | `127.0.0.0/8,::1/128` | proxies whose `X-Forwarded-For`/`X-Real-IP` is believed; add your front door's network |
| `emondrian.mcp.audit.fileMaxMb` / `fileMaxDays` | `50` / `30` | rotation |

An event looks like this, shortened:

```json
{"ts":"2026-10-29T18:06:48.178Z","event":"mcp","direction":"response","transport":"streamable",
 "session":"e939f111-…","client_name":"claude-code","client_ip":"203.0.113.0","principal":"anonymous",
 "method":"tools/call","tool":"execute_query","catalog":"FoodMart","rows":3,"duration_ms":15,
 "response_bytes":245,"status":"ok"}
```

Always present:
- `ts` (UTC);
- `event` (`mcp` or `audit_stats`);
- `method`, `status` (`ok`/`error`), `principal`.

When known, on `mcp` events:
- `direction` (`request`/`response`/`notification`), `session`, `rpc_id`;
- `client_name`/`client_version`/`protocol_version`, `client_ip`, `user_agent`;
- `tool`, `resource`, `prompt`, `catalog`, `cube`, `query`, `query_language`;
- `error_code` (a JSON-RPC code, `tool_error`, or `http_<status>`), `error_message`;
- `duration_ms`, `request_bytes`, `response_bytes`, `rows`;
- `args`/`result` (in `full` mode) or `arg_names` (in `metadata` mode).

**Shipping it to your own Loki or ELK.** Tail the file the way you would any JSON
log, and parse each line as JSON:
- **Labels and keyword fields:** use only `direction`, `method`, `tool` and
  `status`. Session, client and address are high-cardinality, so keep them in
  the body.
- **Timestamp:** take it from `ts`.

Examples:
- **Grafana Alloy or Promtail:** a file source on `logs/mcp-audit.log`, a JSON
  stage extracting those four fields as labels, and a timestamp stage on `ts`
  (RFC 3339).
- **Filebeat:** a `filestream` input with the `ndjson` parser
  (`target: ""`, `add_error_key: true`).

The Enterprise edition ships this already wired to Loki, with a Grafana
dashboard.

---

## Sample Data

Two catalogs are ready after setup:

- **FoodMart** — the classic Mondrian demo schema, on an embedded HSQLDB database. No download, always present.
- **OnTime** — US domestic flight data from the [Bureau of Transportation Statistics](https://transtats.bts.gov/), in ClickHouse. The quick start loads **January 2022 only** (~537,000 rows), which is enough to explore and quick to import.

To load more of the OnTime data, run the dataset script and restart:

```bash
./clickhouse/scripts/setup-ontime.sh --year 2022        # one whole year
./clickhouse/scripts/setup-ontime.sh --year 2022 --months 1,2,3
./clickhouse/scripts/setup-ontime.sh --full             # every year — very large
docker compose up -d
```

Downloaded CSV files are kept in `clickhouse/datasets/ontime/`; delete them once
imported if you need the disk space.

---

## Creating Your Own Cube

Open the schema editor at `http://localhost/schema-editor/` to build a schema in
the browser, or edit the XML directly — the shipped schemas are in `schema/`, and
`schema/Foodmart.xml` includes an example role showing how access to a cube can be restricted.

To point eMondrian at your own database, add a `<Catalog>` to `datasources.xml`
with a JDBC connect string and the path to your schema file. Inside a `<Catalog>`,
write `<DataSourceInfo>` **before** `<Definition>` — the parser reads those two
elements in order, and reversing them silently drops your connect string.

---

## Stopping and Resetting

```bash
docker compose stop          # stop, keep everything
docker compose up -d         # start again
docker compose down          # remove containers, keep the loaded data
docker compose down -v       # remove containers and the ClickHouse data
```

The `logs/` directory is written by the container as `root`; removing it needs
`sudo`.

---

## Licence keys

Most of this edition needs no key. What each part needs:

| What you use | Key needed |
|---|---|
| MDX over `/xmla` — Excel, the browser OLAP client, any MDX client | **None.** Works out of the box |
| The schema and catalog editors, the logs page | **None** |
| **Power BI** (Connect live, DAX queries, CSDL metadata) | A key including **`DAX`** |
| **MCP tools** for AI agents | A key including **`MCP`** |
| The MCP `get_csdl` tool | **Both** `DAX` and `MCP` — it returns the Power BI model through the DAX module |

A free 30-day evaluation key covers both `DAX` and `MCP`:
**https://emondrian.com/license**

Where it goes: put the `.lic` file into the **`modules/` folder next to
`docker-compose.yml`**, the same folder as the module jars. No restart is
needed — the next request picks it up. You can also install it from the entry
page at `http://localhost`.

**Keep exactly one valid `.lic` there.** The server uses the first file that
validates, and with two valid keys in the folder which one that is depends on
the order the filesystem lists them — so delete the old key rather than leaving
it beside the new one. An expired or wrong-module key sitting next to a valid
one is harmless: it is skipped.

Without a key, the licensed paths say what to do rather than failing opaquely —
for example `No eMondrian licence found. Put your .lic file into the modules/
folder …`, or `Your eMondrian licence expired on 2026-10-07. Request an
extension: …`. The file name and the technical reason go to the server log
(`logs/mondrian.log`), not to the client.

---

## A Note on Access Control

The Community Edition ships with **no authentication and no access restrictions**:
anyone who can reach the server can query data, edit schemas and read logs. That
is deliberate for a local evaluation setup on `http://localhost`. Do not expose
this configuration to an untrusted network as it stands.

The MCP endpoint deserves its own mention: it is published on the same port as
the rest, which Docker binds on **all interfaces**, and four of its ten tools
read or write server state rather than query data — `save_schema` overwrites a
catalog's schema XML. Treat reaching this port as administrative access, and
keep the stack on a trusted network or bind `EMONDRIAN_PORT` to localhost. If
nobody needs MCP, turn it off with `ENABLE_SERVICE_MCP=false`.

CORS widens this to the browser: with the default `CORS_ALLOW_ORIGIN=*`, any web
page open in a browser that can reach the server may query `/xmla` and `/api`
through it. Set `CORS_ALLOW_ORIGIN` to the one origin that needs it when the
server holds data that should stay private. Leaving it empty does not close this:
the eMondrian server's own CORS handling still allows simple requests from any origin.

---

## License

EPL-1.0 — see `LICENSE` and `NOTICE` (the modules in `modules/` are proprietary).  

---

## Community vs Enterprise Edition

- **Community Edition**
  - Core OLAP and MDX functionality
  - Free and open-source
  - Intended for evaluation, development, and embedded analytics

- **Enterprise Edition**
  - Advanced security and access control
  - Monitoring and operational features
  - Commercial support and enterprise integrations

More information: https://bisolutions.dev

---

Maintained by the eMondrian Team  
https://bisolutions.dev
