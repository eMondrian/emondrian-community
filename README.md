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

- Docker Engine 20.10 or later
- Docker Compose v2  
  (included with Docker Desktop)

Docker must be installed and running on your system.

---

## Quick Start

Clone the repository and start eMondrian using Docker Compose:

```bash
git clone https://github.com/eMondrian/emondrian-community.git
cd emondrian-community
docker compose up -d
```

Once started, open the main page in your browser:

```
http://localhost
```

---

## Endpoints

After startup, the following endpoints are available:

- **Main Page (UI & tools)**:
  ```
  http://localhost
  ```

- **eMondrian XMLA Server** (for client applications):  
  ```
  http://localhost/xmla
  ```

The XMLA endpoint can be used to connect BI tools and client applications
such as Power BI, Excel, or custom MDX clients.

---

## License

This project is distributed under an open-source license.  
See the `LICENSE` file for details.  

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

