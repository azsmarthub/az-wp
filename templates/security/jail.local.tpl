[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 3
bantime = 7200

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true

[wordpress-login]
enabled = true
port = http,https
filter = wordpress-login
logpath = /var/log/nginx/*-error.log
maxretry = 5
findtime = 300
bantime = 3600
