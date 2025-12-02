# Moodle Docker Image (Production Ready)

Repository responsible for building the customized Moodle Docker image for production use (CapRover, Kubernetes, etc.).

Docker Hub: https://hub.docker.com/repository/docker/esdrascaleb/moodle-docker-php-production/general

This image includes:

- Nginx + PHP-FPM + Supervisor
- Automatic Moodle installation via Git
- Plugin management via JSON
- Dynamic configuration (config.php) via Environment Variables

# 🛠️ How to Build and Submit Manually

1. Build (Build the Image)

In the terminal, inside the project folder:

# Replace 'your-username' with your Docker Hub username
`docker build -t your-username/moodle-php-production:latest .`

2. Test Locally (Complete with Database)

To test the actual flow (Installation + Database):

`docker-compose -f docker-compose.yml up`

Access http://localhost after a few minutes.
