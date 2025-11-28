# Moodle Docker Image (Production Ready)

Repository responsible for building the customized Moodle Docker image for production use (CapRover, Kubernetes, etc.).

This image includes:

Nginx + PHP-FPM + Supervisor

Automatic Moodle installation via Git

Plugin management via JSON

Dynamic configuration (config.php) via Environment Variables

# 🛠️ How to Build and Submit Manually
1. Build (Build the Image)

In the terminal, inside the project folder:

# Replace 'your-username' with your Docker Hub username `docker build -t your-username/moodle-php-production:latest .`

2. Test Locally (Simple)

To see if the script initializes (it will fail the database connection, but validate the build):

`docker run -it --rm -p 8080:80 your-username/moodle-php-production:latest`

3. Test Locally (Complete with Database)

To test the actual flow (Installation + Database):

`docker-compose -f docker-compose.yml up`

Access http://localhost:8080 after a few minutes.

