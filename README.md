# eMondrian Community

**eMondrian Community** is the free and open-source (OSS) edition of **eMondrian** — a ROLAP (Relational OLAP) server for multidimensional data analytics.

It provides an analytical layer on top of relational databases, allowing users to define OLAP cubes, execute MDX queries, and build analytical and BI applications using a transparent, SQL-based model.

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
| `http://localhost/emondrian/mcp/sse` | **MCP endpoint** for AI agents — see below |

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
whatever `EMONDRIAN_PORT` is set to). Transport is HTTP+SSE.

Claude Code:

```bash
claude mcp add --transport sse emondrian http://localhost/emondrian/mcp/sse
```

Any MCP client that speaks HTTP+SSE works the same way — point it at
`http://localhost/emondrian/mcp/sse`. There are no authentication headers.

The `/emondrian/` prefix is part of the URL and not a typo: the server's SSE
handshake tells the client to post back to `/emondrian/mcp/message`, so the
client has to reach that path on this origin.

Things to try once connected:

- *"List the catalogs on this server"* → FoodMart and OnTime
- *"Run this MDX on catalog FoodMart: SELECT {[Measures].[Org Salary]} ON 0 FROM [HR]"*
- *"Which Mondrian properties are set on this server?"*

**The MCP tools need a licence that includes the `MCP` module.** They are the one
part of this edition that is licensed: without it every tool answers
`Module 'MCP' not found in license modules`, while XML/A, the browser client and
the editors keep working. A trial key issued for DAX alone does not cover
it — request one with MCP included. Install it on the entry page, or drop the
`.lic` file into `modules/` and restart the container.

Ten tools are exposed. Four of them — `get_schema`, `validate_schema`,
`save_schema` and `read_logs` — read or **write** server state rather than query
data; `save_schema` overwrites a catalog's schema XML. On this edition nothing is
authenticated, so treat MCP access as administrative access.

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

## A Note on Access Control

The Community Edition ships with **no authentication and no access restrictions**:
anyone who can reach the server can query data, edit schemas and read logs. That
is deliberate for a local evaluation setup on `http://localhost`. Do not expose
this configuration to an untrusted network as it stands.

The MCP endpoint deserves its own mention: it is published on the same port as
the rest, which Docker binds on **all interfaces**, and four of its ten tools
read or write server state rather than query data — `save_schema` overwrites a
catalog's schema XML. Treat reaching this port as administrative access, and
keep the stack on a trusted network or bind `EMONDRIAN_PORT` to localhost.

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
