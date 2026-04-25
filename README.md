# Backend Team local SonarQube

A tool for running local SAST analysis with SonarQube, generating evidence reports, and verifying compliance with the team Quality Gate.

---

## Prerequisites

| Tool                | Minimum version | Required for          |
| ------------------- | --------------- | --------------------- |
| Docker + Compose v2 | Docker 24+      | All                   |
| Java JDK            | 17+             | Maven/Gradle projects |
| Maven               | 3.8+            | Maven projects        |
| Gradle              | 7+              | Gradle projects       |
| Node.js             | 18+             | TypeScript projects   |
| Python 3            | 3.8+            | Support scripts       |

### Check prerequisites

```bash
docker --version && docker compose version
java -version
mvn -version       # Maven projects only
node --version     # TypeScript projects only
python3 --version
```

### macOS — Elasticsearch configuration

No additional configuration is needed on macOS. Docker Desktop automatically manages the `vm.max_map_count` limit.

### Linux — Elasticsearch configuration

```bash
# Persist the setting across reboots
echo "vm.max_map_count=524288" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## Starting SonarQube

Clone the repository and start everything with a single command:

```bash
git clone <repo-url>
cd backend-team-local-sonarqube

docker compose up -d
```

The first startup takes about 2-3 minutes. Docker Compose will:

1. Start PostgreSQL and wait for it to be ready
2. Start SonarQube Community Edition
3. Automatically run the initial configuration (team Quality Gate, instance name)

The instance will be available at **http://localhost:9000** (default port).

**Credentials:** `admin` / `admin`

> **Note:** SonarQube 26.x enforces a minimum password length of 12 characters. The default `admin` password works for API access (analysis, report export). If you change it via the UI you must use at least 12 characters and update `SONAR_USER`/`SONAR_PASSWORD` in `.env`.

### Status and logs

```bash
docker compose ps            # container status
docker compose logs -f       # live logs
docker compose logs sonarqube-setup  # Quality Gate setup logs
```

### Stopping

```bash
docker compose down          # stop containers (data is preserved)
docker compose down -v       # stop and delete all data
```

---

## Configuration

All user-facing settings live in a **`.env`** file at the root of the repository.
A template with all available variables and their defaults is provided as **`.env.example`**.

On first use, copy the template and edit as needed:

```bash
cp .env.example .env
# then edit .env
```

```dotenv
# Host port for SonarQube
SONAR_PORT=9000

# Admin credentials
SONAR_USER=admin
SONAR_PASSWORD=admin

# Quality Gate thresholds (ratings: 1=A  2=B  3=C  4=D  5=E)
QG_NAME=Backend Team QG
QG_MAX_VIOLATIONS=10
QG_MIN_HOTSPOTS_REVIEWED=100
QG_MIN_COVERAGE=80
QG_MAX_DUPLICATIONS=15
QG_MAX_MAINTAINABILITY=1   # A
QG_MAX_RELIABILITY=3       # C
QG_MAX_SECURITY=3          # C
```

---

## Running with Podman

All commands work identically with Podman. Replace `docker` with `podman` throughout:

```bash
podman compose up -d
podman compose ps
podman compose logs -f
podman compose down
```

### Prerequisites for Podman

| Requirement | Notes |
|---|---|
| Podman | 4.0+ recommended |
| podman-compose | `pip install podman-compose` — or use `podman compose` if your distro ships it |
| Podman socket | Must be running so `podman-compose` can reach the API |

### Enable the Podman socket

**macOS (Podman Desktop or CLI):**

```bash
podman machine init   # only on first use
podman machine start
```

**Linux (systemd):**

```bash
# User-level socket (no root required)
systemctl --user enable --now podman.socket
```

### vm.max_map_count on Linux with Podman

Elasticsearch (bundled in SonarQube) requires a high `vm.max_map_count`. With rootless Podman the setting must be applied on the **host**, not inside the container:

```bash
sudo sysctl -w vm.max_map_count=524288
# To persist across reboots:
echo "vm.max_map_count=524288" | sudo tee -a /etc/sysctl.conf
```

### Podman Desktop

If you use [Podman Desktop](https://podman-desktop.io), the `podman compose` command is available from the integrated terminal and behaves identically to the steps above.

---

## Analyzing a project

The `analyze.sh` script must be run **from the root of the project** you want to analyze.

```bash
# Auto-detect the project type
cd /path/to/your/project
/path/to/backend-team-local-sonarqube/analyze.sh

# Or specify the type explicitly
analyze.sh --type maven
analyze.sh --type gradle
analyze.sh --type typescript

# Specify a custom project key
analyze.sh --project-key my-backend-project
```

The script will:

1. Run tests and collect coverage
2. Launch the SonarQube analysis
3. Wait for it to complete
4. Display the Quality Gate result
5. Print a direct link to the dashboard

---

## Configuring coverage collection

Coverage is required to meet the team threshold (≥ 80%).

### Maven — JaCoCo

Add the plugin to your `pom.xml`:

```xml
<build>
  <plugins>
    <plugin>
      <groupId>org.jacoco</groupId>
      <artifactId>jacoco-maven-plugin</artifactId>
      <version>0.8.11</version>
      <executions>
        <execution>
          <id>prepare-agent</id>
          <goals><goal>prepare-agent</goal></goals>
        </execution>
        <execution>
          <id>report</id>
          <phase>verify</phase>
          <goals><goal>report</goal></goals>
        </execution>
      </executions>
    </plugin>
  </plugins>
</build>
```

Then run:

```bash
mvn verify
# XML report will be at: target/site/jacoco/jacoco.xml
```

### Gradle — JaCoCo

Add to `build.gradle`:

```groovy
plugins {
    id 'jacoco'
}

test {
    finalizedBy jacocoTestReport
}

jacocoTestReport {
    dependsOn test
    reports {
        xml.required = true
    }
}
```

Or `build.gradle.kts`:

```kotlin
plugins {
    jacoco
}

tasks.test {
    finalizedBy(tasks.jacocoTestReport)
}

tasks.jacocoTestReport {
    dependsOn(tasks.test)
    reports {
        xml.required.set(true)
    }
}
```

Then run:

```bash
./gradlew test jacocoTestReport
# XML report will be at: build/reports/jacoco/test/jacocoTestReport.xml
```

### TypeScript — Jest

Install the required dependencies:

```bash
npm install --save-dev jest @types/jest ts-jest
# If not already present:
npm install --save-dev jest-sonar-reporter
```

Configure `jest.config.js` (or `jest.config.ts`):

```js
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  collectCoverage: true,
  coverageDirectory: 'coverage',
  coverageReporters: ['lcov', 'text'],
  // Required for SonarQube reporting
  testResultsProcessor: 'jest-sonar-reporter',
};
```

Or add to `package.json`:

```json
{
  "scripts": {
    "test": "jest --coverage"
  },
  "jest": {
    "collectCoverage": true,
    "coverageDirectory": "coverage",
    "coverageReporters": ["lcov", "text"]
  }
}
```

Then run:

```bash
npm test
# LCOV report will be at: coverage/lcov.info
```

---

## Exporting the SAST report

After each analysis, generate the HTML report to attach to your Jira/Confluence task:

```bash
/path/to/backend-team-local-sonarqube/export-report.sh --project-key <project-key>

# Custom output path
export-report.sh --project-key my-project --output ./evidence/sast-report.html

# Skip automatic browser opening
export-report.sh --project-key my-project --no-browser
```

The HTML report includes:

- Quality Gate result (PASSED / FAILED, prominently displayed)
- All key metrics (bugs, vulnerabilities, coverage, duplications...)
- Letter-graded ratings with colour coding (Maintainability, Reliability, Security)
- A detailed table showing each condition against the team thresholds

---

## Team Quality Gate

The **"Backend Team QG"** Quality Gate is automatically configured on first startup.
Thresholds are defined in `.env` and applied at startup:

| Variable                    | Default | Meaning                                    |
| --------------------------- | ------- | ------------------------------------------ |
| `QG_MAX_VIOLATIONS`         | `10`    | Maximum total issues allowed               |
| `QG_MIN_HOTSPOTS_REVIEWED`  | `100`   | % security hotspots that must be reviewed  |
| `QG_MIN_COVERAGE`           | `80`    | Minimum line coverage %                    |
| `QG_MAX_DUPLICATIONS`       | `15`    | Maximum duplicated lines %                 |
| `QG_MAX_MAINTAINABILITY`    | `1`     | Maintainability rating (1=A … 5=E)         |
| `QG_MAX_RELIABILITY`        | `3`     | Reliability rating (1=A … 5=E)             |
| `QG_MAX_SECURITY`           | `3`     | Security rating (1=A … 5=E)                |

To change the thresholds edit `.env` and [force a reconfiguration](#quality-gate-not-configured).

---

## Typical workflow

```bash
# 1. Start SonarQube (if not already running)
cd ~/backend-team-local-sonarqube
docker compose up -d

# 2. Go to your project root
cd ~/my-project

# 3. Run the analysis
btls analyze

# 4. Export the report
btls export-report --project-key my-project

# 5. Attach the generated HTML file to your Jira/Confluence task
```

---

## btls — global CLI command

The repository includes a `btls` wrapper script that exposes `analyze` and `export-report` as subcommands so you can run them from any project directory without specifying the full path.

### Installation (one-time)

```bash
# 1. Make ~/.local/bin available (skip if already in PATH)
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # or ~/.bashrc
source ~/.zshrc

# 2. Create the btls wrapper pointing to the repo
BTLS_HOME="/path/to/backend-team-local-sonarqube"   # ← change this
cat > ~/.local/bin/btls <<EOF
#!/usr/bin/env bash
export BTLS_HOME="${BTLS_HOME}"
exec "\${BTLS_HOME}/btls" "\$@"
EOF
chmod +x ~/.local/bin/btls
```

> If you move the repository, update `BTLS_HOME` in `~/.local/bin/btls`.

### Usage

```bash
# Analyze the project in the current directory
cd /path/to/your/project
btls analyze

# Specify type or project key explicitly
btls analyze --type typescript
btls analyze --project-key my-api

# Export the HTML report
btls export-report --project-key my-api
btls export-report --project-key my-api --output ./evidence/report.html --no-browser

# Help
btls help
```

---

## Typical workflow

---

## Troubleshooting

**SonarQube fails to start (Elasticsearch error)**

On Linux:

```bash
sudo sysctl -w vm.max_map_count=524288
```

**"Port 9000 already in use"**

```bash
docker compose down
# Edit .env and change SONAR_PORT, then restart:
# SONAR_PORT=9001
docker compose up -d
```

**Analysis fails with "Project not found"**

The project is created automatically on the first analysis. Make sure SonarQube is UP:

```bash
curl http://localhost:9000/api/system/status
```

**Quality Gate not configured**

Check the setup container logs:

```bash
docker compose logs sonarqube-setup
```

To force reconfiguration:

```bash
docker compose rm -f sonarqube-setup
docker volume rm backend-team-local-sonarqube_sonarqube_setup_done
docker compose up -d
```
