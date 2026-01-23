# Moodle Docker Image (Production Ready)

Repository responsible for building the customized Moodle Docker image for production use (CapRover, Kubernetes, etc.)

Docker Hub: https://hub.docker.com/repository/docker/esdrascaleb/moodle-docker-php-production/general

A robust, self-contained, and **immutable** Moodle Docker image designed for production environments like **CapRover**, Docker Swarm, and Kubernetes.

Unlike standard images, this image acts as a complete stack (Sidecar pattern) running Nginx, PHP-FPM, and Cron under a Supervisor process. It follows the **"Build-Time Provisioning"** philosophy, meaning Moodle Core and Plugins are baked into the image for faster startup and reliability.

### 🚀 Key Features

-   **All-in-One:** Runs Nginx (Web Server), PHP-FPM, and Moodle Cron in a single container.

-   **Immutable Build:** Moodle source code and plugins are downloaded during `docker build`. The code directory is owned by root and is read-only.

-   **Dynamic Configuration:** Generates `config.php` at build time but reads database/URL settings from Environment Variables at runtime.

-   **Plugin Management:** Install plugins automatically via JSON argument during the build.

-   **CapRover Ready:** Optimized to handle SSL termination and path routing out-of-the-box.

🏃 1. Runtime Environment Variables (`ENV`)
-------------------------------------------

These variables are used **when starting the container**. Changing them affects the running instance immediately after a restart (no rebuild needed). Use these for connections and secrets.

| **Variable**              | **Description**                                                                                         | **Required?**                                        |
|:--------------------------|:--------------------------------------------------------------------------------------------------------|:-----------------------------------------------------|
| `MOODLE_VERSION`          | The Branch or Tag of Moodle to install.                                                                 | No (Default: `MOODLE_405_STABLE`   )                 |
| `MOODLE_GIT_REPO`         | Source repository for Moodle Core.                                                                      | No (Default: `https://github.com/moodle/moodle.git`) |
| `MOODLE_PLUGINS_JSON`     | JSON string array of plugins to install. Format: [{"giturl":"...","installpath":"...","branch":"..."}]. | No (Default: `"[]"` (Empty))                         |
| `MOODLE_EXTRA_PHP`        | Raw PHP code to inject into `config.php` *permanently*.                                                 | No Default(`""` (Empty))                             |
| `MOODLE_LANG`             | Moodle default lang                                                                                     | No Default(`en`)                                     |
| `MOODLE_ADMIN_USER`       | Moodle default admin username                                                                           | No Default(`admin`)                                  |
| `MOODLE_ADMIN_PASS`       | Moodle default admin password                                                                           | No Default(`MoodleAdmin123!`)                        |
| `MOODLE_ADMIN_EMAIL`      | Moodle default admin email                                                                              | No Default(`admin@example.com`)                      |
| `MOODLE_SITE_FULLNAME`    | Moodle site full name in instalation                                                                    | No Default(`Moodle Site`)                            |
| `MOODLE_SITE_SHORTNAME`   | Moodle site short name in instalation                                                                   | No Default(`Moodle`)                                 |
| `MOODLE_SUPPORT_EMAIL`    | Moodle default support email                                                                            | No Default(`support@example.com`)                    |
| `MOODLE_NOREPLY_EMAIL`    | Moodle default noreply email                                                                            | No Default(`noreply@example.com`)                    |
| `MOODLE_URL`              | **Critical.** The public URL (e.g., `https://moodle.com`).                                              | **Yes**                                              |
| `DB_HOST`                 | Database Hostname.                                                                                      | **Yes**                                              |
| `DB_NAME`                 | Database Name.                                                                                          | No (Default: `moodle`)                               |
| `DB_USER`                 | Database User.                                                                                          | No (Default: `moodle`)                               |
| `DB_PASS`                 | Database Password.                                                                                      | **Yes**                                              |
| `DB_TYPE`                 | Database Type Eg `pgsql` or `mysqli`...                                                                 | No (Default: `pgsql`)                                |
| `DB_PORT`                 | Database Port.                                                                                          | No (Default: `5432`)                                 |
| `DB_PREFIX`               | Colluns Prefix                                                                                          | No (Default: `mdl`)                                  |
| `PHP_MEMORY_LIMIT`        | Maximum memory per script (e.g., `512M`, `1G`).                                                         | No (Default: `512M`)                                 |
| `PHP_UPLOAD_MAX_FILESIZE` | Maximum file upload size (e.g., `100M`).                                                                | No (Default: `100M`)                                 |
| `PHP_POST_MAX_SIZE`       | Maximum POST size (must be >= upload size).                                                             | No (Default: `100M`)                                 |
| `PHP_MAX_EXECUTION_TIME`  | Script execution timeout (in seconds).                                                                  | No (Default: `600`)                                  |
| `PHP_MAX_INPUT_VARS`      | Maximum number of input variables (increase for large forms/gradebooks).                                | No (Default: `5000`)                                 |
| `SITE_CODE_STATUS`        | See below                                                                                               | `reset`                                              |
| `PLUGIN_CODE_STATUS`      | See below                                                                                               | `update`                                             |

Code status Controls how Git handles updates:
- **static:** Does nothing if the folder already exists. Faster boot. 
- **reset:** Forces a `git reset --hard` (overwrites local changes and mantain the first download version). 
- **update:** Downloads the latest version and performs a `git pull` (attempts to keep local changes). 

Reset and update cleans up untracked files (`git clean -fdx`).




🏃 2. System Paths
-------------------------------------------

After the container is running, configure Moodle system paths:

**Site Administration → Server → System Paths**

| Tool            | Path               | Purpose |
|-----------------|--------------------|---------|
| PHP             | `/usr/bin/local/php` | PHP binary used by Moodle |
| du              | `/usr/bin/du`        | Disk usage calculations |
| aspell          | `/usr/bin/aspell`    | Spell checking |
| dot (Graphviz)  | `/usr/bin/dot`       | Graph generation |
| ghostscript     | `/usr/bin/gs`        | PDF processing |
| pdftoppm        | `/usr/bin/pdftoppm`  | PDF thumbnails and image conversion |
| python          | `/usr/bin/python3`   | Required by document conversion and ML plugins |



🛠️ 3. Usage Guide
---------------

### A. Using with Docker Compose

This example shows how to mix Build-Time args (to choose version) and Runtime envs (to connect to DB).

```
services:
  db:
    image: postgres:18.1-alpine
    environment:
      POSTGRES_USER: moodle
      POSTGRES_PASSWORD: password
      POSTGRES_DB: moodle
    volumes:
      - db_data:/var/lib/postgresql/18/docker

  app:
    build:
      context: .
    ports:
      - "80:80"
    depends_on:
      - db
    environment:
      MOODLE_URL: http://localhost
      DB_HOST: db
      DB_TYPE: pgsql
      DB_NAME: moodle
      DB_USER: moodle
      DB_PASS: password
      MOODLE_VERSION: MOODLE_405_STABLE
      MOODLE_LANG: pt_br
      MOODLE_ADMIN_USER: admin
      MOODLE_ADMIN_PASS: MoodleAdmin123!
      MOODLE_ADMIN_EMAIL: admin@example.com
      PHP_MEMORY_LIMIT: 512M
      PHP_MAX_EXECUTION_TIME: 600
      MOODLE_PLUGINS_JSON: |
        [
          {
            "giturl": "https://github.com/h5p/moodle-mod_hvp.git",
            "branch": "stable",
            "installpath": "mod/hvp"
          },
          {
            "giturl": "https://github.com/davosmith/moodle-checklist.git",
            "branch": "master",
            "installpath": "mod/checklist"
          }
        ]
      MOODLE_EXTRA_PHP: "$$CFG->debug = 32767; $$CFG->debugdisplay = 1;"
    volumes:
      # Persistência do moodledata localmente
      - moodle_data:/var/www/moodledata

volumes:
  db_data:
  moodle_data:

```

### B. Using with CapRover

Since CapRover typically pulls the *already built* image, you only need to configure the **Runtime Variables**.

1.  **Deploy via One-Click App (Template):** Use the template provided in the GitHub repository.

2.  **Manual Configuration:**

    -   Create an App (e.g., `moodle`).

    -   Go to **App Configs**.

    -   Add the **Runtime Variables** (`MOODLE_URL`, `DB_HOST`, etc.).

    -   Add a **Persistent Directory**: Path `/var/www/moodledata` -> Label `moodledata`.

    -   **Enable HTTPS** and ensure `MOODLE_URL` starts with `https://`.

Fixing HTTPS/Redirect Loops in CapRover:

If you encounter redirect loops behind CapRover's load balancer, add this variable to App Configs:

`MOODLE_EXTRA_PHP` = `$CFG->sslproxy = 1; $CFG->reverseproxy = 1;`

*(Note: In CapRover UI, use single `$` for variables. In Docker Compose files, use `$$`).*

📂 5. Persistence
--------------

-   **`/var/www/moodledata`**: Stores uploaded files, sessions, and cache. **MUST be persisted.**

-   **`/var/www/moodle`**: Contains the application code. **Do NOT persist this.** The code is immutable and inside the image. To update Moodle, simply restart image.

🏷️ 6. Tags
--------------
**🏔️ Alpine** - Uses alpine focused to **↔️ horizontal scaling**

**🌀 Debian** - Uses debian focused in **↕️ vertical scaling**, and has support to **🪟 Microsoft SQL Server**

🧩 7. Compatibility
--------------
These images were created with the LTS versions in mind, but they also work with Moodle 5.0 and 5.1. If you run into any issues, contact the author.