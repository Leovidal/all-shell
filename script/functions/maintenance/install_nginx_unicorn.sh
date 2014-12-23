#!/usr/bin/env bash

sudo apt-get --force-yes install nginx monit ufw
gem install rails unicorn --no-ri --no-rdoc

sudo echo "export RAILS_ENV=production" >> /etc/environment
sudo groupadd cmilfont
sudo useradd -m -g cmilfont -s /bin/bash cmilfont
sudo passwd cmilfont
sudo su -c "echo \"%cmilfont ALL=(ALL) ALL\" >> /etc/sudoers" - root

sudo mkdir /home/cmilfont/.ssh

scp ~/.ssh/id_rsa.pub cmilfont@localhost:.ssh/authorized_keys2

sudo mkdir /home/cmilfont/n1r

sudo cp n1r-nginx-default /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/n1r-nginx-default /etc/nginx/sites-enabled/
sudo mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.temp
sudo cp nginx.conf /etc/nginx/nginx.conf

sudo su -c "mkdir /usr/local/nginx" - root

gem install bundler capistrano --no-ri --no-rdoc

#sudo ln -s /home/cmilfont/.rvm/gems/ruby-1.8.7-p302/gems/unicorn-3.0.1/bin/unicorn_rails /usr/bin/unicorn_rails

#capify .
#cp unicorn.rb
sudo update-rc.d -f unicorn remove
sudo cp n1r_unicorn /etc/init.d/unicorn
sudo chmod +x /etc/init.d/unicorn
sudo update-rc.d unicorn defaults

sudo rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-available/default

sudo apt-get install mysql-server
sudo apt-get install libmysqlclient-dev
bundle install

