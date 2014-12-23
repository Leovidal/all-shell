#!/usr/bin/env bash

#ferramentas para o rvm
sudo apt-get -y install sed grep tar curl ssh perl g++
sudo apt-get -y install zlibc
sudo apt-get -y install zlib1g
sudo apt-get -y install zlib1g-dev
sudo apt-get -y install zlib-bin
sudo apt-get -y install openssl
sudo apt-get -y install libcurl3
sudo apt-get -y install expat
sudo apt-get -y install git
sudo apt-get -y install libxml2
sudo apt-get -y install libxml2-dev
sudo apt-get -y install ruby-dev
sudo apt-get -y install libxslt1-dev
sudo apt-get -y install mysql-server
sudo apt-get -y install libmysqlclient-dev
sudo apt-get -y install imagemagick
sudo apt-get -y install librmagick-ruby
sudo apt-get -y install libmagick++3
sudo apt-get -y install libgraphicsmagick3
sudo apt-get -y install libgraphicsmagick1-dev
sudo apt-get -y install libmagick++-3
sudo apt-get -y install libpng3
sudo apt-get -y install libopenssl-ruby
sudo apt-get -y install libssl-dev
sudo apt-get -y install libssl0.9.8
sudo apt-get -y install libreadline5-dev

#sudo ./install-system-wide

# Install RVM
#cd ~/
mkdir -p ~/.rvm/src/
cd ~/.rvm/src
#rm -rf ./rvm/
git clone --depth 1 git://github.com/wayneeseguin/rvm.git
cd rvm
./install

# Install some rubies
#source "$HOME/.rvm/scripts/rvm"
sudo rvm install 1.8.7
sudo rvm use 1.8.7
sudo rvm rubygems 1.3.7
sudo rvm --default 1.8.7
gem update --system

#echo "source /usr/local/lib/rvm" >> ~/.bashrc

# install gems from Cordel App
#mkdir ~/dev
#cd ~/dev
#git clone git@github.com:cmilfont/rr10-team-116.git
#gem install bundler
#cd rr10-team-116
#bundle install

