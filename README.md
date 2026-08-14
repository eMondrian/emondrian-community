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

### Windows

Run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1
```

If WSL 2 is not installed or needs to be updated, the setup script may require a Windows restart. After restarting Windows, open PowerShell in the project directory and run the same command again:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1
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