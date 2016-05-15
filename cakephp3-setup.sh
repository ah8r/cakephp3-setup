#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "This script can only be run as root.";
    exit 1;
fi

DIR=`pwd`/cakephp-setup-`date +%s`;
mkdir $DIR;

# Update Repositories
apt-get update;

# Install Essentials
apt-get install curl git wget unzip;

# Install MySQL Server & Setup
apt-get install mysql-server;
/usr/sbin/mysqld --initialize 2> /dev/null;
/usr/bin/mysql_secure_installation;

# Install Nginx, PHP-FPM, and phpMyAdmin.
apt-get install nginx php7.0 php7.0-cli php7.0-intl php7.0-zip php7.0-fpm php7.0-mysql php7.0-mbstring php7.0-gettext phpmyadmin;

# Edit PHP-FPM to work with Nginx.
sed -i "s/^;cgi\.fix_pathinfo=1$/cgi.fix_pathinfo=0/" /etc/php/7.0/fpm/php.ini;
sed -i "s/^cgi\.fix_pathinfo=1$/cgi.fix_pathinfo=0/" /etc/php/7.0/fpm/php.ini;

# Restart PHP-FPM
service php7.0-fpm restart;

# Set up SSL
if [ ! -d /etc/nginx/ssl ]; then mkdir /etc/nginx/ssl; fi;
cd /etc/nginx/ssl;
if [ ! -f /etc/nginx/ssl/nginx.key ] && [ ! -f /etc/nginx/ssl/nginx.crt ]; then openssl req -x509 -sha256 -nodes -days 3650 -newkey rsa:2048 -keyout nginx.key -out nginx.crt; fi;
if [ ! -f /etc/nginx/ssl/dhparams.pem ]; then openssl dhparam -out dhparams.pem 2048; fi;


# Set up Directories
if [ -d /var/www/html ]; then rm -rf /var/www/html; fi;
mkdir -p /var/www/cakephp;
mkdir -p /var/www/cakephp/logs;
mkdir -p /var/www/cakephp/public;

# Set up Nginx config.
cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default-`date +%s`.bckp;

echo 'server {
    listen 80;
    listen 443 ssl;

    server_name cakephp;
    
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    access_log /var/www/cakephp/logs/access.log combined;
    error_log /var/www/cakephp/logs/error.log;

    client_max_body_size 20M;
    
    root /var/www/cakephp/public;
    index index.php index.html index.htm;
    
    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    
    fastcgi_intercept_errors on;
    
    location ~ \.php$ {
        expires epoch;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php7.0-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
    }

    location /phpmyadmin {
        location ~* \.(css|js|ico|gif|png|jpeg|jpg|woff|map)$ {
            root /var/www/cakephp/public;
            try_files $uri =404;
        }
    }

    location ~* \.(css|js|ico|gif|png|jpeg|jpg|woff|map)$ {
        root /var/www/cakephp/public/webroot;
        try_files $uri =404;
    }
    
    location ~ /\. {
        deny all;
    }
}' > /etc/nginx/sites-available/default;

# SSL Extras

echo '  ssl_dhparam /etc/nginx/ssl/dhparams.pem;

        ssl_session_timeout 5m;
        ssl_session_cache shared:SSL:50m;

        ssl_ciphers -ALL:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:ECDH-RSA-AES256-GCM-SHA384:ECDH-ECDSA-AES256-GCM-SHA384:ECDH-RSA-AES256-SHA384:ECDH-ECDSA-AES256-SHA384:ECDH-RSA-AES256-SHA:ECDH-ECDSA-AES256-SHA:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDH-RSA-AES128-GCM-SHA256:ECDH-ECDSA-AES128-GCM-SHA256:ECDH-RSA-AES128-SHA256:ECDH-ECDSA-AES128-SHA256:ECDH-RSA-AES128-SHA:ECDH-ECDSA-AES128-SHA;' > /etc/nginx/conf.d/ssl-extra.conf;

# Working Fastcgi Parameters

echo 'fastcgi_param  QUERY_STRING       $query_string;
fastcgi_param  REQUEST_METHOD     $request_method;
fastcgi_param  CONTENT_TYPE       $content_type;
fastcgi_param  CONTENT_LENGTH     $content_length;

fastcgi_param  SCRIPT_FILENAME    $request_filename;
fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
fastcgi_param  REQUEST_URI        $request_uri;
fastcgi_param  DOCUMENT_URI       $document_uri;
fastcgi_param  DOCUMENT_ROOT      $document_root;
fastcgi_param  SERVER_PROTOCOL    $server_protocol;
fastcgi_param  REQUEST_SCHEME     $scheme;
fastcgi_param  HTTPS              $https if_not_empty;

fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;

fastcgi_param  REMOTE_ADDR        $remote_addr;
fastcgi_param  REMOTE_PORT        $remote_port;
fastcgi_param  SERVER_ADDR        $server_addr;
fastcgi_param  SERVER_PORT        $server_port;
fastcgi_param  SERVER_NAME        $server_name;

# PHP only, required if PHP was built with --enable-force-cgi-redirect
fastcgi_param  REDIRECT_STATUS    200;' > /etc/nginx/fastcgi_params;

# Restart Nginx
service nginx stop;
service nginx start;

# Install CakePHP
cd /var/www/cakephp;
curl -s https://getcomposer.org/installer | php;
php composer.phar create-project --prefer-dist cakephp/app public;
mv composer.phar public/composer.phar;

# Install Bootstrap Helpers
cd /var/www/cakephp/public;
php composer.phar require holt59/cakephp3-bootstrap-helpers:dev-master
echo -e "\nPlugin::load('Bootstrap');" >> config/bootstrap.php;

# Create Symlink to phpMyAdmin
ln -s -f /usr/share/phpmyadmin /var/www/cakephp/public;

cd $DIR;

# Download and install Bootstrap CSS
wget -O bootstrap.zip 'https://github.com/twbs/bootstrap/releases/download/v3.3.6/bootstrap-3.3.6-dist.zip';
unzip -d bootstrap bootstrap.zip;
cp bootstrap/*/js/*.js /var/www/cakephp/public/webroot/;
cp bootstrap/*/css/*.css /var/www/cakephp/public/webroot/css/;
cp -r bootstrap/*/fonts /var/www/cakephp/public/webroot/fonts;

echo 'body {
  padding-top: 70px;
  padding-bottom: 30px;
}

.theme-dropdown .dropdown-menu {
  position: static;
  display: block;
  margin-bottom: 20px;
}

.theme-showcase > p > .btn {
  margin: 5px 0;
}

.theme-showcase .navbar .container {
  width: auto;
}' > /var/www/cakephp/public/webroot/css/theme.css;

# Download and install jQuery
wget -O jquery.min.js 'https://code.jquery.com/jquery-2.2.3.min.js';
cp jquery.min.js /var/www/cakephp/public/webroot/js/;

# Create Layout

echo '<!DOCTYPE html>
<html>
<head>
    <?= $this->Html->charset(); ?>
    
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <?= $this->Html->meta('icon'); ?>
    <title><?= $this->fetch('title'); ?></title>
    <?= $this->Html->css('bootstrap.min.css'); ?>
    <?= $this->Html->css('bootstrap-theme.min.css'); ?>
    <?= $this->Html->css('theme.css'); ?>
    <?= $this->fetch('meta'); ?>
    <?= $this->fetch('css'); ?>
    <?= $this->fetch('script'); ?>
</head>
<body role="document">
    <!-- Fixed navbar -->
    <nav class="navbar navbar-inverse navbar-fixed-top">
      <div class="container">
        <div class="navbar-header">
          <button type="button" class="navbar-toggle collapsed" data-toggle="collapse" data-target="#navbar" aria-expanded="false" aria-controls="navbar">
            <span class="sr-only">Toggle navigation</span>
            <span class="icon-bar"></span>
            <span class="icon-bar"></span>
            <span class="icon-bar"></span>
          </button>
          <a class="navbar-brand" href="#">CakePHP</a>
        </div>
        <div id="navbar" class="navbar-collapse collapse">
          <ul class="nav navbar-nav">
            <li class="active"><a href="#">Home</a></li>
            <li><a href="#about">About</a></li>
            <li><a href="#contact">Contact</a></li>
            <li class="dropdown">
              <a href="#" class="dropdown-toggle" data-toggle="dropdown" role="button" aria-haspopup="true" aria-expanded="false">Dropdown <span class="caret"></span></a>
              <ul class="dropdown-menu">
                <li><a href="#">Action</a></li>
                <li><a href="#">Another action</a></li>
                <li><a href="#">Something else here</a></li>
                <li role="separator" class="divider"></li>
                <li class="dropdown-header">Nav header</li>
                <li><a href="#">Separated link</a></li>
                <li><a href="#">One more separated link</a></li>
              </ul>
            </li>
          </ul>
        </div>
      </div>
    </nav>
    <div class="container theme-showcase" role="main">
    <?= $this->Flash->render(); ?>
    <?= $this->fetch('content'); ?>
    </div>
    <?= $this->Html->script('jquery.min.js'); ?>
    <?= $this->Html->script('bootstrap.min.js'); ?>
</body>
</html>' > /var/www/cakephp/public/src/Template/Layout/default.ctp;

# Set Ownership
chown -R www-data:www-data /var/www/cakephp/*;
chmod -R g+w /var/www/cakephp/public/;

rm -rf $DIR;

echo "##################################################";
echo "#                                                #";
echo "#               IMPORTANT! READ!                 #";
echo "#                                                #";
echo "##################################################";

echo "Add the following lines to AppController.php to enable Bootstrap Helpers:";
echo "";
echo "public \$helpers = [
    'Html' => [
        'className' => 'Bootstrap.BootstrapHtml'
    ],
    'Form' => [
        'className' => 'Bootstrap.BootstrapForm'
    ],
    'Paginator' => [
        'className' => 'Bootstrap.BootstrapPaginator'
    ],
    'Modal' => [
        'className' => 'Bootstrap.BootstrapModal'
    ]
];";
