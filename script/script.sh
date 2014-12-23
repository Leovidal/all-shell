#!/bin/bash
## Elaborated by Leovidal

. ./reg.sh

menu(){
	echo "Choose an option:  
	1) Clear RAM
	2) Mercurial Server
	3) Kill CPU
	e) Exit
	l) Licence
	c) Credits
	"
	echo "Type your selection: "
	
	read selection

	case $selection in 
		1) 
			dropcache
			;;
		2)
			hg
			;;
		3) 
			kill_cpu
			;;
		4) ;;
		5) ;;
		l)
			licence
			;;
		c)
			credits
			;;
		*)
			
	esac
}

user(){
	auth_user="root"

	if [ $USER != $auth_user ]; then
		echo "Este script debe ser ejecutado por el usuario $auth_user" 1>&2
		exit 1
	else 
		menu
	fi

}

lockfile(){
	proc="leovidal"
	lockfile=/var/lock/$proc.lock

	if ( set -o noclobber; echo "$$" > "$lockfile") 2> /dev/null; then
		trap 'rm -f "$lockfile"; exit $?' INT TERM EXIT
		menu
		rm -f "$lockfile"
		trap - INT TERM EXIT
	else
		echo "This process is running..."
		echo "PID: $(cat $lockfile)"
		echo "Cleaning..."
		rm $lockfile
		menu
	fi
}

more(){

	#
	#Set Colors
	#

	bold=$(tput bold)
	underline=$(tput sgr 0 1)
	reset=$(tput sgr0)

	purple=$(tput setaf 171)
	red=$(tput setaf 1)
	green=$(tput setaf 76)
	tan=$(tput setaf 3)
	blue=$(tput setaf 38)

	#
	# Headers and  Logging
	#

	e_header() { printf "\n${bold}${purple}==========  %s  ==========${reset}\n" "$@" 
	}
	e_arrow() { printf "➜ $@\n"
	}
	e_success() { printf "${green}✔ %s${reset}\n" "$@"
	}
	e_error() { printf "${red}✖ %s${reset}\n" "$@"
	}
	e_warning() { printf "${tan}➜ %s${reset}\n" "$@"
	}
	e_underline() { printf "${underline}${bold}%s${reset}\n" "$@"
	}
	e_bold() { printf "${bold}%s${reset}\n" "$@"
	}
	e_note() { printf "${underline}${bold}${blue}Note:${reset}  ${blue}%s${reset}\n" "$@"
	}


	e_header "I am a sample script"
	e_success "I am a success message"
	e_error "I am an error message"
	e_warning "I am a warning message"
	e_underline "I am underlined text"
	e_bold "I am bold text"
	e_note "I am a note"

}

main(){
	author
	lockfile
}

main
