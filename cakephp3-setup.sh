#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "This script can only be run as root.";
    exit 1;
fi

OS=`cat /etc/os-release | grep -Po '(?<=^NAME=")[^"]+(?=")'`;
VERSION=`cat /etc/os-release | grep -Po '(?<=^VERSION_ID=")[0-9]+(?=\.[0-9]+")'`;

if [ "$OS" != "Ubuntu" ]; then
    echo -e "WARNING: This script was designed to run on Ubuntu, but $OS was detected.\nIf $OS is an Ubuntu derivative then this script might run successfully, but it may require some edits to work.\nPress enter to continue.";
    read cont;
    
    # Assume Ubuntu derivatives are still using php5. If you are reading this message and your distro supports php7.0, set the VERSION variable to 16 below.
    VERSION=15;
fi

VALID_HOSTNAME=false;
while [ "$VALID_HOSTNAME" = false ]; do
        echo -n "Enter the hostname of the virtual host you want to create: ";
        read HOSTNAME;

        # Check hostname is allowed.
        if [ "`echo $HOSTNAME | grep -P '^(?!\-)(?:[a-zA-Z\d\-]{0,62}[a-zA-Z\d]\.?){1,126}(?!\d+)[a-zA-Z\d]{1,63}$'`" == $HOSTNAME ]; then
                if [ ! -d /var/www/$HOSTNAME ]; then
            echo "Creating web server directory structure in /var/www/$HOSTNAME.";
                        mkdir -p /var/www/$HOSTNAME;
                        mkdir -p /var/www/$HOSTNAME/logs;
                        mkdir -p /var/www/$HOSTNAME/public;
                        VALID_HOSTNAME=true;
                else
                        echo "ERROR: This hostname appears to already exist (/var/www/$HOSTNAME exists). Either choose another hostname or remove the /var/www/$HOSTNAME directory and re-run the script.";
                fi
        fi
done;

if [ $VERSION -ge 16 ]; then
    PHP_PACKAGES=('php7.0' 'php7.0-intl' 'php7.0-zip' 'php7.0-fpm' 'php7.0-mysql' 'php7.0-mbstring' 'php-gettext');
    PHP_DIR='/etc/php/7.0';
    PHP_FPM_COMMAND='php7.0-fpm';
    PHP_FPM_SOCK='/var/run/php/php7.0-fpm.sock';
else
    PHP_PACKAGES=('php5' 'php5-cli' 'php5-fpm' 'php5-intl' 'php5-mysql');
    PHP_DIR='/etc/php5';
    PHP_FPM_COMMAND='php5-fpm';
    PHP_FPM_SOCK='/var/run/php5-fpm.sock';
fi

PACKAGES=('curl' 'git' 'wget' 'unzip' 'mysql-server' 'nginx' "${PHP_PACKAGES[@]}" 'phpmyadmin');

declare -a INSTALL_PACKAGES;
INSTALL_MYSQL=false;
for PACKAGE in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' $PACKAGE 2> /dev/null | grep -q -P '^install ok installed$';
    if [ $? -eq 1 ]; then
        INSTALL_PACKAGES+=("$PACKAGE");
        if [ "$PACKAGE" == "mysql-server" ]; then
            INSTALL_MYSQL=true;
        fi
    fi
done;

DIR=/tmp/cakephp3-setup-`date +%s`;
echo "Making temporary directory $DIR for storing downloaded files.";
mkdir $DIR;


if [ ${#INSTALL_PACKAGES[@]} -gt 0 ]; then
    # Update Repositories
    echo "Updating repositories.";
    apt-get update > /dev/null;

    if [ $? -ne 0 ]; then echo -e "Error updating repositories.\nYou may wish to cancel this script and run \"apt-get update\" to see what the problem is, as other parts of this script require Internet connectivity. Press enter to continue."; read cont; fi

    # Install Packages
    echo "Installing the following missing packages: ${INSTALL_PACKAGES[@]}.";
    apt-get -q install "${INSTALL_PACKAGES[@]}";
    
    # If mysql-server was installed, initialize it and secure it
    if [ "$INSTALL_MYSQL" == true ]; then
        /usr/sbin/mysqld --initialize 2> /dev/null;
        /usr/bin/mysql_secure_installation;
    fi
fi

# Edit PHP-FPM to work with Nginx.
echo "Editing $PHP_DIR/fpm/php.ini to ensure it works with Nginx.";
sed -i "s/^;cgi\.fix_pathinfo=1$/cgi.fix_pathinfo=0/" $PHP_DIR/fpm/php.ini;
sed -i "s/^cgi\.fix_pathinfo=1$/cgi.fix_pathinfo=0/" $PHP_DIR/fpm/php.ini;

# Restart PHP-FPM
echo "Restarting $PHP_FPM_COMMAND service.";
service $PHP_FPM_COMMAND restart;

# Set up SSL
if [ ! -d /etc/nginx/ssl ]; then
    echo "Creating /etc/nginx/ssl directory to store keys and certificates."
    mkdir /etc/nginx/ssl;
fi;
if [ ! -f /etc/nginx/ssl/$HOSTNAME.key ] || [ ! -f /etc/nginx/ssl/$HOSTNAME.crt ]; then
    echo "Generating SSL key /etc/nginx/ssl/$HOSTNAME.key and self-signed certificate /etc/nginx/ssl/$HOSTNAME.crt.";
    openssl req -x509 -sha256 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/nginx/ssl/$HOSTNAME.key -out /etc/nginx/ssl/$HOSTNAME.crt;
fi;
if [ ! -f /etc/nginx/ssl/dhparams.pem ]; then
    echo "Generating 2048bit /etc/nginx/ssl/dhparams.pem.";
    openssl dhparam -out /etc/nginx/ssl/dhparams.pem 2048;
fi;

# Create Nginx configuration file.
echo "Creating Nginx configuration file /etc/nginx/sites-available/$HOSTNAME.";
echo "server {
    listen 80;
    listen 443 ssl;

    server_name $HOSTNAME;
    
    ssl_certificate /etc/nginx/ssl/$HOSTNAME.crt;
    ssl_certificate_key /etc/nginx/ssl/$HOSTNAME.key;

    access_log /var/www/$HOSTNAME/logs/access.log combined;
    error_log /var/www/$HOSTNAME/logs/error.log;

    client_max_body_size 20M;
    
    root /var/www/$HOSTNAME/public;
    index index.php index.html index.htm;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    fastcgi_intercept_errors on;
    
    location ~ \\.php$ {
        expires epoch;
        fastcgi_split_path_info ^(.+\\.php)(/.+)$;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_index index.php;
        include fastcgi_params;
    }

    location /phpmyadmin {
        location ~* \\.(css|js|ico|gif|png|jpeg|jpg|woff|map)$ {
            root /var/www/$HOSTNAME/public;
            try_files \$uri =404;
        }
    }

    location ~* \\.(css|js|ico|gif|png|jpeg|jpg|woff|map|eot|svg|ttf|woff2)$ {
        root /var/www/$HOSTNAME/public/webroot;
        try_files \$uri =404;
    }
    
    location ~ /\\. {
        deny all;
    }
}" > /etc/nginx/sites-available/$HOSTNAME;

# Create symbolic link to Nginx config file.
echo "Creating symbolic link /etc/nginx/sites-enabled/$HOSTNAME to Nginx configuration file /etc/nginx/sites-available/$HOSTNAME.";
ln -s /etc/nginx/sites-available/$HOSTNAME /etc/nginx/sites-enabled/$HOSTNAME;

# SSL Extras
if [ -f /etc/nginx/conf.d/ssl-extra.conf ]; then
    echo -n "/etc/nginx/conf.d/ssl-extra.conf exists, do you wish to overwrite it? (recommended unless you have made changes to this file) y/N: ";
    read SSL_OVERWRITE;
fi

if [ ! -f /etc/nginx/conf.d/ssl-extra.conf ] || [[ $SSL_OVERWRITE =~ ^[Yy](es)?$ ]]; then
    echo "Writing secure SSL/TLS setup to /etc/nginx/conf.d/ssl-extra.conf.";
    echo '  ssl_dhparam /etc/nginx/ssl/dhparams.pem;

        ssl_session_timeout 5m;
        ssl_session_cache shared:SSL:50m;

        ssl_ciphers -ALL:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:ECDH-RSA-AES256-GCM-SHA384:ECDH-ECDSA-AES256-GCM-SHA384:ECDH-RSA-AES256-SHA384:ECDH-ECDSA-AES256-SHA384:ECDH-RSA-AES256-SHA:ECDH-ECDSA-AES256-SHA:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDH-RSA-AES128-GCM-SHA256:ECDH-ECDSA-AES128-GCM-SHA256:ECDH-RSA-AES128-SHA256:ECDH-ECDSA-AES128-SHA256:ECDH-RSA-AES128-SHA:ECDH-ECDSA-AES128-SHA;' > /etc/nginx/conf.d/ssl-extra.conf;
fi

# Working Fastcgi Parameters
if [ -f /etc/nginx/fastcgi_params ]; then
    echo -n "/etc/nginx/fastcgi_params exists, do you wish to overwrite it? (recommended unless you have made changes to this file) y/N: ";
    read FASTCGI_OVERWRITE;
fi

if [ ! -f /etc/nginx/fastcgi_params ] || [[ $FASTCGI_OVERWRITE =~ ^[Yy](es)?$ ]]; then
    echo "Writing FastCGI parameters to /etc/nginx/fastcgi_params.";
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
fi

# Restart Nginx
echo "Restarting Nginx service.";
service nginx stop;
service nginx start;

# Install CakePHP
cd /var/www/$HOSTNAME;
echo "Downloading PHP Composer.";
curl -s https://getcomposer.org/installer | php;
echo "Creating CakePHP project in /var/www/$HOSTNAME/public.";
php composer.phar create-project --prefer-dist cakephp/app public;
mv composer.phar public/composer.phar;

# Install Bootstrap Helpers
cd /var/www/$HOSTNAME/public;
echo "Installing CakePHP3 Bootstrap Helpers.";
php composer.phar require holt59/cakephp3-bootstrap-helpers:dev-master
echo -e "\nPlugin::load('Bootstrap');" >> config/bootstrap.php;

# Create symbolic link to phpMyAdmin
echo "Creating symbolic link /var/www/$HOSTNAME/public/phpmyadmin to /usr/share/phpmyadmin.";
ln -s -f /usr/share/phpmyadmin /var/www/$HOSTNAME/public;

cd $DIR;

# Download and install Bootstrap CSS
echo "Downloading & installing Bootstrap.";
wget -q -O bootstrap.zip 'https://github.com/twbs/bootstrap/releases/download/v3.3.6/bootstrap-3.3.6-dist.zip';
unzip -qq -d bootstrap bootstrap.zip;
cp bootstrap/*/js/*.js /var/www/$HOSTNAME/public/webroot/js/;
cp bootstrap/*/css/*.css /var/www/$HOSTNAME/public/webroot/css/;
cp -r bootstrap/*/fonts /var/www/$HOSTNAME/public/webroot/fonts;

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
}' > /var/www/$HOSTNAME/public/webroot/css/theme.css;

# Download and install jQuery
echo "Downloading and installing jQuery.";
wget -q -O jquery.min.js 'https://code.jquery.com/jquery-2.2.3.min.js';
cp jquery.min.js /var/www/$HOSTNAME/public/webroot/js/;

# Create Layout
echo "Creating Bootstrap layout for CakePHP.";
echo $'<!DOCTYPE html>
<html>
<head>
    <?= $this->Html->charset(); ?>
    
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <?= $this->Html->meta(\'icon\'); ?>
    <title><?= $this->fetch(\'title\'); ?></title>
    <?= $this->Html->css(\'bootstrap.min.css\'); ?>
    <?= $this->Html->css(\'bootstrap-theme.min.css\'); ?>
    <?= $this->Html->css(\'theme.css\'); ?>
    <?= $this->fetch(\'meta\'); ?>
    <?= $this->fetch(\'css\'); ?>
    <?= $this->fetch(\'script\'); ?>
</head>
<body role="document">
    <!-- Fixed navbar -->
    <nav class="navbar navbar-inverse navbar-fixed-top">
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
    </nav>
    <div class="container theme-showcase" role="main">
    <?= $this->Flash->render(); ?>
    <?= $this->fetch(\'content\'); ?>
    </div>
    <?= $this->Html->script(\'jquery.min.js\'); ?>
    <?= $this->Html->script(\'bootstrap.min.js\'); ?>
</body>
</html>' > /var/www/$HOSTNAME/public/src/Template/Layout/default.ctp;

# Set Ownership
echo "Changing file ownership to www-data:www-data and giving group write access.";
chown -R www-data:www-data /var/www/$HOSTNAME/*;
chmod -R g+w /var/www/$HOSTNAME/public/;

echo "Removing temporary download directory.";
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
    ],
    'Flash' => [
        'className' => 'Bootstrap.BootstrapFlash'
    ],
    'Navbar' => [
        'className' => 'Bootstrap.BootstrapNavbar'
    ],
    'Panel' => [
        'className' => 'Bootstrap.BootstrapPanel'
    ]
];";
