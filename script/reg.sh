#This file registry each one of created functions
func=./functions
util=$func/utilities
srv=$func/servers
db=$func/databases


#Credits
. ./credits.sh

#Licence
. ./licence.sh

#Utilities
#Droping caches
. $util/drop_cache.sh
. $util/ifs_test.sh
. $util/kill_cpu.sh

#Servers
#Mercurial
. $srv/hg-serve.sh

#Databases
. $db/backup_db.sh
