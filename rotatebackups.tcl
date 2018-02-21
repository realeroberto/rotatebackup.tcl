#!/usr/bin/tclsh

################################################################################
#
# rotatebackups - A simple Tcl utility for backup rotation.
#
# Copyright (c) 2014-8 Roberto Reale
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
################################################################################


## 
## We require several packages (to be found in the TCLLIB collection).
##

package require Tcl 8.4
package require inifile
package require logger
package require syslog


## 
## Local configuration
##

set progname "rotatebackups"
set config_file "/etc/$progname.ini"
set version 0.1
set logger_interactive 0
set logger_handler [logger::init $progname]
set logger_ident $progname
set logger_facility "user"
set logger_priority "notice"



proc logger {message} {
	global logger_interactive
	global logger_handler
	global logger_ident
	global logger_facility
	global logger_priority

	if { $logger_interactive } {
		${logger_handler}::notice $message
	} else {
		syslog -ident $logger_ident -facility $logger_facility $logger_priority $message
	}
}

proc test_interactive {} {

	# see http://www.tcl.tk/man/tcl8.4/TclCmd/exec.htm

	if {[catch {exec test -t 0} results]} {
		if {[lindex $::errorCode 0] eq "CHILDSTATUS"} {
			return 0
		} else {
			# some kind of unexpected failure
			return 0
		}
	} else {
		return 1
	}
}

proc get_branch_name {backup_subroot format branch_number} {
	return [file join $backup_subroot [format $format $branch_number]]
}

proc get_associated_name {file_name regexp subst} {
	return [regsub $regexp $file_name $subst]
}

proc get_lock_name {file_name regexp subst} {
	return [get_associated_name $file_name $regexp $subst]
}

proc get_sha1_name {file_name regexp subst} {
	return [get_associated_name $file_name $regexp $subst]
}

proc touch_file {file_name} {
	close [open $file_name "w"]
}

proc acquire_lock {file_name regexp subst} {
	set lock_name [get_lock_name $file_name $regexp $subst]
	if {[file exists $lock_name]} {
		return 0
	} else {
		touch_file $lock_name
		return 1
	}
}

proc release_lock {file_name regexp subst} {
	set lock_name [get_lock_name $file_name $regexp $subst]
	if {[file exists $lock_name]} {
		file delete -force $lock_name
	}
}

proc verify_backup_tree {backup_subroot format size} {
	for {set i 0} {$i < $size} {incr i} {
		set branch [get_branch_name $backup_subroot $format $i]
		if {![file isdirectory $branch]} {
			# log
			file mkdir $branch
		}
	}
}

proc rotate_backups {backup_subroot file format size} {
	set basename [file tail $file]

	for {set i [expr $size-1]} {$i > 0} {incr i -1} {
		set branch_prev [get_branch_name $backup_subroot $format [expr $i - 1]]
		set file_prev [file join $branch_prev $basename]
		if {[file exists $file_prev]} {
			set branch_curr [get_branch_name $backup_subroot $format $i]
			set file_curr [file join $branch_curr $basename]
			file copy -force $file_prev $file_curr
			file delete -force $file_prev
		}
	}
}

proc backup_file {backup_subroot source_file             \
			lock_regexp lock_subst           \
			sha1_regexp sha1_subst           \
			branch_format tree_size} {

	# acquire the lock
	if {![acquire_lock $source_file $lock_regexp $lock_subst]} {
		logger "Cannot acquire lock!"
		return 0
	}

	# make room
	logger "Rotating $source_file ..."
	rotate_backups $backup_subroot $source_file $branch_format $tree_size

	# copy the file
	logger "Copying file $source_file ..."
	file copy -force $source_file [get_branch_name $backup_subroot $branch_format 0]

	# copy the associated SHA1 file
	set sha1_file [get_sha1_name $source_file $sha1_regexp $sha1_subst] 
	if {[file isfile $sha1_file]} {
		file copy -force $sha1_file [get_branch_name $backup_subroot $branch_format 0]
	} else {
		# log
	}

	# release the lock
	release_lock $source_file $lock_regexp $lock_subst
}

proc get_config_value {config section key} {
	return [string trim [::ini::value $config $section $key] "\""]
}

proc do_backup {config_file} {
	set config [::ini::open $config_file "r"]

	foreach section [::ini::sections $config] {
		if {$section == "__system__"} {
			set backup_root [get_config_value $config $section "backup_root"]
		}
	}

	foreach section [::ini::sections $config] {

		if {$section == "__system__"} {continue}

		if {[get_config_value $config $section "enabled"] != "true"} {continue}

		set source_files_expression [get_config_value $config $section "source_files_expression"]
		set backup_tree_size [get_config_value $config $section "backup_tree_size"]
		set branch_format [get_config_value $config $section "branch_format"]
		set lock_regexp [get_config_value $config $section "lock_regexp"]
		set lock_subst [get_config_value $config $section "lock_subst"]
		set sha1_regexp [get_config_value $config $section "sha1_regexp"]
		set sha1_subst [get_config_value $config $section "sha1_subst"]

		set backup_subroot [file join $backup_root $section]

		verify_backup_tree $backup_subroot $branch_format $backup_tree_size

		foreach file [glob -type f $source_files_expression] {
			backup_file $backup_subroot $file $lock_regexp $lock_subst \
				$sha1_regexp $sha1_subst $branch_format $backup_tree_size
		}
	}

	::ini::close $config
}


##
## BEGIN MAIN PROGRAM
set logger_interactive [test_interactive]
logger "Starting ..."
do_backup $config_file
## END MAIN PROGRAM
##

# ex: ts=4 sw=4 et filetype=tcl noexpandtab
