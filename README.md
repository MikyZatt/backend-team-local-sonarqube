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

The instance will be available at **http://localhost:9000**

**Credentials:** `admin` / `admin`

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

The **"Backend Team QG"** Quality Gate is automatically configured on first startup with these thresholds:

| Metric                     | Threshold       |
| -------------------------- | --------------- |
| Total Issues               | ≤ 10            |
| Security Hotspots Reviewed | = 100%          |
| Code Coverage              | ≥ 80%           |
| Duplicated Lines           | ≤ 15%           |
| Maintainability Rating     | no worse than A |
| Reliability Rating         | no worse than C |
| Security Rating            | no worse than C |

---

## Typical workflow

```bash
# 1. Start SonarQube (if not already running)
cd ~/backend-team-local-sonarqube
docker compose up -d

# 2. Go to your project root
cd ~/my-project

# 3. Run the analysis
~/backend-team-local-sonarqube/analyze.sh

# 4. Export the report
~/backend-team-local-sonarqube/export-report.sh --project-key my-project

# 5. Attach the generated HTML file to your Jira/Confluence task
```

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
# Or change the port in docker-compose.yml: "9001:9000"
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
