#!/usr/bin/tclsh

package provide tar 0.10

namespace eval ::tar {}

proc ::tar::parseOpts {acc opts} {
  array set flags $acc
  foreach {x y} $acc {upvar $x $x}

  set len [llength $opts]
  set i 0
  while {$i < $len} {
    set name [string trimleft [lindex $opts $i] -]
    if {![info exists flags($name)]} {return -code error "unknown option \"$name\""}
    if {$flags($name) == 1} {
      set $name [lindex $opts [expr {$i + 1}]]
      incr i $flags($name)
    } elseif {$flags($name) > 1} {
      set $name [lrange $opts [expr {$i + 1}] [expr {$i + $flags($name)}]]
      incr i $flags($name)
    } else {
      set $name 1
    }
    incr i
  }
}

proc ::tar::pad {size} {
  set pad [expr {512 - ($size % 512)}]
  if {$pad == 512} {return 0}
  return $pad
}

proc ::tar::seekorskip {ch off wh} {
  if {[tell $ch] < 0} {
    if {$wh!="current"} {
      error "WHENCE=$wh not supported on non-seekable channel $ch"
    }
    skip $ch $off
    return
  }
  seek $ch $off $wh
  return
}

proc ::tar::skip {ch skipover} {
  while {$skipover > 0} {
    set requested $skipover

    # Limit individual skips to 64K, as a compromise between speed
    # of skipping (Number of read requests), and memory usage
    # (Note how skipped block is read into memory!). While the
    # read data is immediately discarded it still generates memory
    # allocation traffic, gets copied, etc. Trying to skip the
    # block in one go without the limit may cause us to run out of
    # (virtual) memory, or just induce swapping, for nothing.

    if {$requested > 65536} {
      set requested 65536
    }

    set skipped [string length [read $ch $requested]]

    # Stop in short read into the end of the file.
    if {!$skipped && [eof $ch]} break

    # Keep track of how much is (not) skipped yet.
    incr skipover -$skipped
  }
  return
}

proc ::tar::readHeader {data} {
  binary scan $data a100a8a8a8a12a12a8a1a100a6a2a32a32a8a8a155 \
  name mode uid gid size mtime cksum type \
  linkname magic version uname gname devmajor devminor prefix

  foreach x {name type linkname} {
    set $x [string trim [set $x] "\x00"]
  }
  foreach x {uid gid size mtime cksum} {
    set $x [format %d 0[string trim [set $x] " \x00"]]
  }
  set mode [string trim $mode " \x00"]

  if {$magic == "ustar "} {
    # gnu tar
    # not fully supported
    foreach x {uname gname prefix} {
      set $x [string trim [set $x] "\x00"]
    }
    foreach x {devmajor devminor} {
      set $x [format %d 0[string trim [set $x] " \x00"]]
    }
  } elseif {$magic == "ustar\x00"} {
    # posix tar
    foreach x {uname gname prefix} {
      set $x [string trim [set $x] "\x00"]
    }
    foreach x {devmajor devminor} {
      set $x [format %d 0[string trim [set $x] " \x00"]]
    }
  } else {
    # old style tar
    foreach x {uname gname devmajor devminor prefix} { set $x {} }
    if {$type == ""} {
      if {[string match */ $name]} {
        set type 5
      } else {
        set type 0
      }
    }
  }

  return [list name $name mode $mode uid $uid gid $gid size $size mtime $mtime \
  cksum $cksum type $type linkname $linkname magic $magic \
  version $version uname $uname gname $gname devmajor $devmajor \
  devminor $devminor prefix $prefix]
}

proc ::tar::contents {file args} {
  set chan 0
  parseOpts {chan 0} $args
  if {$chan} {
    set fh $file
  } else {
    set fh [::open $file]
    fconfigure $fh -encoding binary -translation lf -eofchar {}
  }
  set ret {}
  while {![eof $fh]} {
    array set header [readHeader [read $fh 512]]
    HandleLongLink $fh header
    if {$header(name) == ""} break
    if {$header(prefix) != ""} {append header(prefix) /}
    lappend ret $header(prefix)$header(name)
    seekorskip $fh [expr {$header(size) + [pad $header(size)]}] current
  }
  if {!$chan} {
    close $fh
  }
  return $ret
}

proc ::tar::stat {tar {file {}} args} {
  set chan 0
  parseOpts {chan 0} $args
  if {$chan} {
    set fh $tar
  } else {
    set fh [::open $tar]
    fconfigure $fh -encoding binary -translation lf -eofchar {}
  }
  set ret {}
  while {![eof $fh]} {
    array set header [readHeader [read $fh 512]]
    HandleLongLink $fh header
    if {$header(name) == ""} break
    if {$header(prefix) != ""} {append header(prefix) /}
    seekorskip $fh [expr {$header(size) + [pad $header(size)]}] current
    if {$file != "" && "$header(prefix)$header(name)" != $file} {continue}
    set header(type) [string map {0 file 5 directory 3 characterSpecial 4 blockSpecial 6 fifo 2 link} $header(type)]
    set header(mode) [string range $header(mode) 2 end]
    lappend ret $header(prefix)$header(name) [list mode $header(mode) uid $header(uid) gid $header(gid) \
    size $header(size) mtime $header(mtime) type $header(type) linkname $header(linkname) \
    uname $header(uname) gname $header(gname) devmajor $header(devmajor) devminor $header(devminor)]
  }
  if {!$chan} {
    close $fh
  }
  return $ret
}

proc ::tar::get {tar file args} {
  set chan 0
  parseOpts {chan 0} $args
  if {$chan} {
    set fh $tar
  } else {
    set fh [::open $tar]
    fconfigure $fh -encoding binary -translation lf -eofchar {}
  }
  while {![eof $fh]} {
    set data [read $fh 512]
    array set header [readHeader $data]
    HandleLongLink $fh header
    if {$header(name) == ""} break
    if {$header(prefix) != ""} {append header(prefix) /}
    set name [string trimleft $header(prefix)$header(name) /]
    if {$name == $file} {
      set file [read $fh $header(size)]
      if {!$chan} {
        close $fh
      }
      return $file
    }
    seekorskip $fh [expr {$header(size) + [pad $header(size)]}] current
  }
  if {!$chan} {
    close $fh
  }
  return {}
}

proc ::tar::untar {tar args} {
  set nooverwrite 0
  set data 0
  set nomtime 0
  set noperms 0
  set chan 0
  parseOpts {dir 1 file 1 glob 1 nooverwrite 0 nomtime 0 noperms 0 chan 0} $args
  if {![info exists dir]} {set dir [pwd]}
  set pattern *
  if {[info exists file]} {
    set pattern [string map {* \\* ? \\? \\ \\\\ \[ \\\[ \] \\\]} $file]
  } elseif {[info exists glob]} {
    set pattern $glob
  }

  set ret {}
  if {$chan} {
    set fh $tar
  } else {
    set fh [::open $tar]
    fconfigure $fh -encoding binary -translation lf -eofchar {}
  }
  while {![eof $fh]} {
    array set header [readHeader [read $fh 512]]
    HandleLongLink $fh header
    if {$header(name) == ""} break
    if {$header(prefix) != ""} {append header(prefix) /}
    set name [string trimleft $header(prefix)$header(name) /]
    if {![string match $pattern $name] || ($nooverwrite && [file exists $name])} {
      seekorskip $fh [expr {$header(size) + [pad $header(size)]}] current
      continue
    }

    set name [file join $dir $name]
    if {![file isdirectory [file dirname $name]]} {
      file mkdir [file dirname $name]
      lappend ret [file dirname $name] {}
    }
    if {[string match {[0346]} $header(type)]} {
      if {[catch {::open $name w+} new]} {
        # sometimes if we dont have write permission we can still delete
        catch {file delete -force $name}
        set new [::open $name w+]
      }
      fconfigure $new -encoding binary -translation lf -eofchar {}
      fcopy $fh $new -size $header(size)
      close $new
      lappend ret $name $header(size)
    } elseif {$header(type) == 5} {
      file mkdir $name
      lappend ret $name {}
    } elseif {[string match {[12]} $header(type)] && $::tcl_platform(platform) == "unix"} {
      catch {file delete $name}
      if {![catch {file link [string map {1 -hard 2 -symbolic} $header(type)] $name $header(linkname)}]} {
        lappend ret $name {}
      }
    }
    seekorskip $fh [pad $header(size)] current
    if {![file exists $name]} continue

    if {$::tcl_platform(platform) == "unix"} {
      if {!$noperms} {
        catch {file attributes $name -permissions 0[string range $header(mode) 2 end]}
      }
      catch {file attributes $name -owner $header(uid) -group $header(gid)}
      catch {file attributes $name -owner $header(uname) -group $header(gname)}
    }
    if {!$nomtime} {
      file mtime $name $header(mtime)
    }
  }
  if {!$chan} {
    close $fh
  }
  return $ret
}

##
# ::tar::statFile
#
# Returns stat info about a filesystem object, in the form of an info
# dictionary like that returned by ::tar::readHeader.
#
# The mode, uid, gid, mtime, and type entries are always present.
# The size and linkname entries are present if relevant for this type
# of object. The uname and gname entries are present if the OS supports
# them. No devmajor or devminor entry is present.
##

proc ::tar::statFile {name followlinks} {
  if {$followlinks} {
    file stat $name stat
  } else {
    file lstat $name stat
  }

  set ret {}

  if {$::tcl_platform(platform) == "unix"} {
    lappend ret mode 1[file attributes $name -permissions]
    lappend ret uname [file attributes $name -owner]
    lappend ret gname [file attributes $name -group]
    if {$stat(type) == "link"} {
      lappend ret linkname [file link $name]
    }
  } else {
    lappend ret mode [lindex {100644 100755} [expr {$stat(type) == "directory"}]]
  }

  lappend ret  uid $stat(uid)  gid $stat(gid)  mtime $stat(mtime) \
  type $stat(type)

  if {$stat(type) == "file"} {lappend ret size $stat(size)}

  return $ret
}

##
# ::tar::formatHeader
#
# Opposite operation to ::tar::readHeader; takes a file name and info
# dictionary as arguments, returns a corresponding (POSIX-tar) header.
#
# The following dictionary entries must be present:
#   mode
#   type
#
# The following dictionary entries are used if present, otherwise
# the indicated default is used:
#   uid       0
#   gid       0
#   size      0
#   mtime     [clock seconds]
#   linkname  {}
#   uname     {}
#   gname     {}
#
# All other dictionary entries, including devmajor and devminor, are
# presently ignored.
##

proc ::tar::formatHeader {name info} {
  array set A {
    linkname ""
    uname ""
    gname ""
    size 0
    gid  0
    uid  0
  }
  set A(mtime) [clock seconds]
  array set A $info
  array set A {devmajor "" devminor ""}

  set type [string map {file 0 directory 5 characterSpecial 3 \
  blockSpecial 4 fifo 6 link 2 socket A} $A(type)]

  set osize  [format %o $A(size)]
  set ogid   [format %o $A(gid)]
  set ouid   [format %o $A(uid)]
  set omtime [format %o $A(mtime)]

  set name [string trimleft $name /]
  if {[string length $name] > 255} {
    return -code error "path name over 255 chars"
  } elseif {[string length $name] > 100} {
    set common [string range $name end-99 154]
    if {[set splitpoint [string first / $common]] == -1} {
      return -code error "path name cannot be split into prefix and name"
    }
    set prefix [string range $name 0 end-100][string range $common 0 $splitpoint-1]
    set name   [string range $common $splitpoint+1 end][string range $name 155 end]
  } else {
    set prefix ""
  }

  set header [binary format a100A8A8A8A12A12A8a1a100A6a2a32a32a8a8a155a12 \
  $name $A(mode)\x00 $ouid\x00 $ogid\x00\
  $osize\x00 $omtime\x00 {} $type \
  $A(linkname) ustar\x00 00 $A(uname) $A(gname)\
  $A(devmajor) $A(devminor) $prefix {}]

  binary scan $header c* tmp
  set cksum 0
  foreach x $tmp {incr cksum $x}

  return [string replace $header 148 155 [binary format A8 [format %o $cksum]\x00]]
}


proc ::tar::recurseDirs {files followlinks} {
  foreach x $files {
    if {[file isdirectory $x] && ([file type $x] != "link" || $followlinks)} {
      if {[set more [glob -dir $x -nocomplain *]] != ""} {
        eval lappend files [recurseDirs $more $followlinks]
      } else {
        lappend files $x
      }
    }
  }
  return $files
}

proc ::tar::writefile {in out followlinks name} {
  puts -nonewline $out [formatHeader $name [statFile $in $followlinks]]
  set size 0
  if {[file type $in] == "file" || ($followlinks && [file type $in] == "link")} {
    set in [::open $in]
    fconfigure $in -encoding binary -translation lf -eofchar {}
    set size [fcopy $in $out]
    close $in
  }
  puts -nonewline $out [string repeat \x00 [pad $size]]
}

proc ::tar::create {tar files args} {
  set dereference 0
  set chan 0
  parseOpts {dereference 0 chan 0} $args

  if {$chan} {
    set fh $tar
  } else {
    set fh [::open $tar w+]
    fconfigure $fh -encoding binary -translation lf -eofchar {}
  }
  foreach x [recurseDirs $files $dereference] {
    writefile $x $fh $dereference $x
  }
  puts -nonewline $fh [string repeat \x00 1024]

  if {!$chan} {
    close $fh
  }
  return $tar
}

proc ::tar::add {tar files args} {
  set dereference 0
  set prefix ""
  set quick 0
  parseOpts {dereference 0 prefix 1 quick 0} $args

  set fh [::open $tar r+]
  fconfigure $fh -encoding binary -translation lf -eofchar {}

  if {$quick} then {
    seek $fh -1024 end
  } else {
    set data [read $fh 512]
    while {[regexp {[^\0]} $data]} {
      array set header [readHeader $data]
      seek $fh [expr {$header(size) + [pad $header(size)]}] current
      set data [read $fh 512]
    }
    seek $fh -512 current
  }

  foreach x [recurseDirs $files $dereference] {
    writefile $x $fh $dereference $prefix$x
  }
  puts -nonewline $fh [string repeat \x00 1024]

  close $fh
  return $tar
}

proc ::tar::remove {tar files} {
  set n 0
  while {[file exists $tar$n.tmp]} {incr n}
  set tfh [::open $tar$n.tmp w]
  set fh [::open $tar r]

  fconfigure $fh  -encoding binary -translation lf -eofchar {}
  fconfigure $tfh -encoding binary -translation lf -eofchar {}

  while {![eof $fh]} {
    array set header [readHeader [read $fh 512]]
    if {$header(name) == ""} {
      puts -nonewline $tfh [string repeat \x00 1024]
      break
    }
    if {$header(prefix) != ""} {append header(prefix) /}
    set name $header(prefix)$header(name)
    set len [expr {$header(size) + [pad $header(size)]}]
    if {[lsearch $files $name] > -1} {
      seek $fh $len current
    } else {
      seek $fh -512 current
      fcopy $fh $tfh -size [expr {$len + 512}]
    }
  }

  close $fh
  close $tfh

  file rename -force $tar$n.tmp $tar
}

proc ::tar::HandleLongLink {fh hv} {
  upvar 1 $hv header thelongname thelongname

  # @LongName Part I.
  if {$header(type) == "L"} {
    # Size == Length of name. Read it, and pad to full 512
    # size.  After that is a regular header for the actual
    # file, where we have to insert the name. This is handled
    # by the next iteration and the part II below.
    set thelongname [string trimright [read $fh $header(size)] \000]
    seekorskip $fh [pad $header(size)] current
    return -code continue
  }
  # Not supported yet: type 'K' for LongLink (long symbolic links).

  # @LongName, part II, get data from previous entry, if defined.
  if {[info exists thelongname]} {
    set header(name) $thelongname
    # Prevent leakage to further entries.
    unset thelongname
  }

  return
}


switch -- $::tcl_platform(platform) {
  "windows"        {
    encoding system cp1251
  }
  "unix" - default {
    encoding system utf-8
  }
}

package require Tk
package require tar
font configure TkDefaultFont -size 10
font configure TkFixedFont -size 10

global typesys
set typesys $::tcl_platform(platform)

if {0} {
  if {$typesys != "windows" } {
    catch {tk_getOpenFile foo bar}
    set ::tk::dialog::file::showHiddenVar 0
    set ::tk::dialog::file::showHiddenBtn 1
    #    ttk::setTheme clearlooks
  }
}


option add *Dialog.msg.wrapLength 6i
option add *Dialog.dtl.wrapLength 6i

wm geometry . +300+105
wm title . "GUI Software Token LS11SW2016"
#. configure -bg red
global p11conf
global libpkcs11
global yespas
global pathtok
global filelic
global home
global create_sw_token
global create_user_license_request
global p11conf
global libls11sw2016
global libpkcs11
set res ""
set libpkcs11 ""
set p11conf ""
global logo
ttk::style map My.TButton -background [list disabled #d9d9d9 pressed #a3a3a3  active #ff6a00] -foreground [list disabled #a3a3a3] -relief [list {pressed !disabled} sunken]
ttk::style configure My.TButton -borderwidth 3 -anchor w -padx 0 -width 20  -background #d9d9d9
# -background wheat
ttk::style map TButton -background [list disabled #d9d9d9 pressed #a3a3a3  active #ff6a00] -foreground [list disabled #a3a3a3] -relief [list {pressed !disabled} sunken]
ttk::style configure TButton -borderwidth 3 -padx 0 -background #39b5da
#ff9060
#ttk::style configure TFrame -background #c0bab4
ttk::style configure TFrame -background #eff0f1
# -width 100 -height 100
#tk::style configure TLabel -background #c0bab4
ttk::style configure TLabel -background #eff0f1
# -width 100 -height 100

switch -- $::tcl_platform(platform) {
  "windows"        { set home $::env(USERPROFILE) }
  "unix" - default { set home $::env(HOME) }
}
set pathtok [file join $home ".LS11SW2016"]
set filelic [file join $pathtok "LIC.DAT"]
set filereq [file join $pathtok "LIC.REQ"]
set pathutil [file join $pathtok "UTIL"]
#set myDir "/home/a513/ORLOV/TK_Tcl/CREATE_SW_TOKEN_TCL/BINARY"
set myDir "/home/a513/ORLOV/TK_Tcl/Project/FREEWRAP/CREATE_SW_TOKEN_TCL/BINARY"
#set myDir "/PROJECT/CREATE_SW_TOKEN_TCL/BINARY"

if {0} {
  switch -- $::tcl_platform(platform) {
    "windows"        {
      set create_sw_token "create_sw_token.exe"
      set create_user_license_request "create_user_license_request.exe"
      set libls11sw2016 "ls11sw2016.dll"
      set p11conf "p11conf.exe"
    }
    "unix" - default {
      set create_sw_token "create_sw_token"
      set create_user_license_request "create_user_license_request"
      set libls11sw2016 "libls11sw2016.so"
      set p11conf "p11conf"
    }
  }
}
##################
set typesys1 [tk windowingsystem]
switch $typesys1 {
  win32        {
    #	set home $::env(USERPROFILE)
    set create_sw_token "create_sw_token.exe"
    set create_user_license_request "create_user_license_request.exe"
    set libls11sw2016 "ls11sw2016.dll"
    set p11conf "p11conf.exe"
  }
  x11 {
    #	set home $::env(HOME)
    catch {tk_getOpenFile foo bar}
    set ::tk::dialog::file::showHiddenVar 0
    set ::tk::dialog::file::showHiddenBtn 1
    set create_sw_token "create_sw_token"
    set create_user_license_request "create_user_license_request"
    set libls11sw2016 "libls11sw2016.so"
    set p11conf "p11conf"
  }
  classic - aqua {
    #	set home $::env(HOME)
    set create_sw_token "create_sw_token"
    set create_user_license_request "create_user_license_request"
    set libls11sw2016 "libls11sw2016.dylib"
    set p11conf "p11conf"
  }
}
##################


if {[file exists $pathutil]} {
  file delete -force  $pathutil
}
if {[file exists [file join $pathtok $libls11sw2016]]} {
  file delete -force  [file join $pathtok $libls11sw2016]
}
file mkdir $pathutil
::freewrap::unpack [file join $myDir $create_sw_token] $pathutil
#	file copy create_sw_token $pathutil
::freewrap::unpack [file join $myDir $create_user_license_request] $pathutil
#	file copy create_user_license_request $pathutil
::freewrap::unpack [file join $myDir  $libls11sw2016] $pathtok
#	file copy libls11sw2016.so $pathutil
::freewrap::unpack [file join $myDir  $p11conf] $pathutil
#	file copy p11conf $pathutil
set create_sw_token [file join $pathutil $create_sw_token]
set create_user_license_request [file join $pathutil $create_user_license_request]
set p11conf [file join $pathutil $p11conf]
set libls11sw2016 [file join $pathtok $libls11sw2016]

set libpkcs11 $libls11sw2016
if {$typesys != "windows" } {
  file attribute $create_sw_token -permissions +x	
  file attribute $create_user_license_request -permissions +x
  file attribute $p11conf -permissions +x	
}
#tk_messageBox -title "P11CONF"   -icon info -message [exec $p11conf]


proc setTempDir {} {
  switch -- $::tcl_platform(platform) {
    "windows"        { set tempDir $::env(TEMP) }
    "unix" - default { set tempDir "/tmp" }
  }
  return $tempDir
}

image create photo icon11_32x32 -data {
  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
}
image create photo exitCA_16x16 -data {
  R0lGODlhEAAQAMYAAP///5gBAfz398+Hh6AVFdJSUsMAANMAAMYAANJRUdNVVcgA
  ANAAANQAANRYWNFOTtBCQtBISNBEROmjo9A/P9VcXOq5ueuysuyKiuq4uOqwsJwH
  B9E8POmpqe/Bwe6jo/jk5NxyctdiYs4aGuSFhfvw8NcaGuyFhdaamthqavHJycMJ
  CeOJiccXF8kfH841Nfba2twaGtEuLtkpKeqYmPCUlLYYGONaWuJsbNciIt1KSt5C
  Qvne3uFhYd57e8sqKrk2Nv//////////////////////////////////////////
  ////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////
  ////////////////////////////////////////////////////////////////
  /////////////////yH+EUNyZWF0ZWQgd2l0aCBHSU1QACwAAAAAEAAQAAAHgIAA
  goOEhYaHhiUEi4yNAYQDFRUOlBoKBQUJHZAOCpcFAAkPo5uDA5kiAA8AAgAREaWC
  A6MAKREAEoIQE5ARKrgSEBAUABy8phCCFCsGzQAGJJAUHM8GCNcAC9Gm2NkLCwAq
  DCeQ3wyEHgwH5KYM7uoHDfIN7IMC9/j5rYj8/YaBADs=
}
image create photo rf_16x16 -data {
  iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAABmJLR0QA/wD/AP+gvaeTAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAB3RJTUUH4AgfCDkuPtts5wAAA1JJ
  REFUOMtlk2tom3UUxn//N2mSJk2Wru06e8m61doOu1bdBUUnTgXp1KlV1soYuCkqTMQbE0SGuAkqDka1WAuVfRzM4oeBuxQnuOmobHNae7U326Rd07S5NGneN8n7Hr9o
  O/T59Hx5fodzeI7iFkXHJyjctJHRsFn0whXrubEY5WV5GvZcLtj7m5zmuCta/KFB5IhzJaP+NUumzqTmLA71/Hqi2yjf57IM1pWv4/tZG/V+RThmcuaG7aQvvfxWcY0j
  2n/AtQoQEYIJfbPX1K/O7dzudtXVMvjmJ/xZshmnDRZ1jQK7xbVpi0sDkqjw5u4Znskfm31fofoWTeo98aKp8ehkZm9TgRg6yswxdW8TobqtTPqq6G1sojrfYo1DkcvA
  UMiMZVRiw5M1roQC6B0OdTl233fQYwNEAMhLxgkFGvhq/3EidduJ6FDpUVR5LIqcCqeY7e/clfea1hMT3/qebw96lLUSprqWwa4e2k9eYjiwjVjKxGmazC5bhNMKC2Fg
  jkMi4tQa3DQbiTgotXrZ0SGktBRbBFIZjWzOxqJho8gpLBggljCxpDg1mnpGS6dzFZN7XsJS2gpANI07WnfiHu8ja4JNE0QUy4bCzFqEU2BqwvVwfkDb4NN4+Yafjhe/
  wGbm/iEIAhx7dwcPBH/G47Io9FrUllgE54SljElTlSKZMUVLprPT2+b7OdR2ANOWd2uviHlLONrRjH5zAWMowR9jgtOliOo2+mMwEZdprSDf2b1n5AzidgPCf6VbGoHL
  V3j+/FHG54SsoZiKCmMR4exTkW5NKZX8saG1c8RXS+nyTRxWBk1MHKZB2dIMv6x/kLNbnqbeGKLlahfJhMVtTjAztClVnrUnJYeHmcOVmQstMr24ZlN0kI9/P8yRxmNc
  rNnF/cOX6Ti1l9r5a4wU17PWZ0esTKR33/x7A4+nsBcoO63fJONv353e2rbgu+77K+qrjIzQfe4x7N9ZLOSvxdBcuHMpJrc8RHO9udDoz+1o6CxO9b3iWt31kS8tRML+
  XR+EO396dLeEyjwSqvJLcGOhBAN+eaPlawl8Lu1PnIh4Xz2X+v83Aowms9xekMenIt7UZz88uzwdr3DoS3x05/4peZ1upVTq4pjOw9Wrk/8GStmTZ9C6w14AAAAASUVO
  RK5CYII=
}

image create photo logoLSTok -data {
  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
}
wm iconphoto . icon11_32x32
. configure  -borderwidth 2 -background #c0bab4 -padx 5 -pady 5

update

#############
proc initTok {createTok} {
  label $createTok.labTok -background #29dfee -justify left -text "Введите метку токена" -anchor w
  grid $createTok.labTok -column 0 -pady 2 -row 0 -sticky we
  entry $createTok.entTok -background snow
  grid $createTok.entTok -column 1 -padx 2 -pady 2 -row 0
  label $createTok.labSoPin -background #29dfee -text "Введите SO PIN" -anchor w
  grid $createTok.labSoPin -column 0 -pady 2 -row 1 -sticky we
  entry $createTok.entSoPin -background snow -show *
  grid $createTok.entSoPin -column 1 -pady 2 -row 1
  label $createTok.labUserPin -background #29dfee -text "Новый PIN-пользователя" -anchor w
  grid $createTok.labUserPin -column 0 -row 2 -sticky we
  entry $createTok.entUserPin -background snow -show *
  grid $createTok.entUserPin -column 1 -pady 2 -row 2
  label $createTok.labRepUserPin -background #29dfee -text "Повторите PIN-пользователя" -anchor w
  grid $createTok.labRepUserPin -column 0 -pady 2 -row 3 -sticky we
  entry $createTok.entRepUserPin -background snow -show *
  grid $createTok.entRepUserPin -column 1 -pady 2 -row 3
  button $createTok.createOk -background #ffe0a6 -command {global yespas;set yespas "yes";
  return} -text Готово
  grid $createTok.createOk -column 0 -pady 4 -row 4
  button $createTok.createCansel -background #ffe0a6 -command {global yespas;set yespas "no";puts "Передумал";
  return} -text Передумал
  grid $createTok.createCansel -column 1 -pady 4 -row 4
  #################
}

wm geometry . +350+100

#frame .st -borderwidth 3 -relief groove -bd 3 -background #39b5da  -padx 5 -pady 10
frame .st -borderwidth 3 -relief groove -bd 3 -background #eff0f1  -padx 5 -pady 10
pack .st -in . -fill both -side top

frame .fr1 -borderwidth 3 -relief groove -background #c0bab4 -highlightbackground #18f1d7 -highlightcolor #18f1d7 -padx 5 -pady 10

#labelframe .fr1.fra82 -text "Управление токеном" -borderwidth 3 -relief groove -padx 5 -pady 5 -bg #39b5da
labelframe .fr1.fra82 -text "Управление токеном" -borderwidth 3 -relief groove -padx 5 -pady 5 -bg #eff0f1
pack .fr1.fra82 -in .fr1 -anchor center -expand 1 -fill both -padx 5 -side left

#frame .fr1.fra82.frl -borderwidth 3 -relief groove -padx 5 -pady 5 -bg #39b5da
frame .fr1.fra82.frl -borderwidth 0 -relief flat -padx 2 -pady 2 -bg #eff0f1
pack .fr1.fra82.frl  -anchor center -expand 1 -fill both -padx 5 -side top


labelframe  .fr1.fra82.frl.labelframeinit -text "Первичная Инициализация токена" -bd 3 -bg #ffd8b0
image create photo logoLC -file [file join $myDir "my_orel_380x150.png"]
label  .fr1.fra82.frl.labelinit -bd 3 -bg #39b5da -image logoLC -compound center
# -width 152 -height 380
initTok {.fr1.fra82.frl.labelframeinit}
#label  .fr1.fra82.lstok -bg #39b5da -disabledforeground #b8a786 -highlightbackground #ffd8b0 -fg snow
label  .fr1.fra82.lstok -bg #eff0f1 -disabledforeground #b8a786 -highlightbackground #39b5da -fg blue
.fr1.fra82.lstok configure -font  {"Tahoma Bold" 18 bold}
#-fg snow
.fr1.fra82.lstok configure -text  "LS11SW2016\nCryptographic Token\nPKCS#11 v.2.40"

set stylebut "  -activebackground #f9f9f9 -background #ffe0a6 "
#frame .fr1.fra82.fb1 -relief groove -bg #39b5da -width 125 -highlightbackground #ffd8b0
#frame .fr1.fra82.fb2 -relief groove -bg #39b5da -width 125 -highlightbackground #ffd8b0
#frame .fr1.fra82.fb3 -relief groove -bg #39b5da -width 125 -highlightbackground #ffd8b0
frame .fr1.fra82.fb1 -relief groove -bg #eff0f1 -width 125 -highlightbackground #ffd8b0
frame .fr1.fra82.fb2 -relief groove -bg #eff0f1 -width 125 -highlightbackground #ffd8b0
frame .fr1.fra82.fb3 -relief groove -bg #eff0f1 -width 125 -highlightbackground #ffd8b0

set borbut " -highlightthickness 4 -relief flat -highlightbackground #39b5da -activebackground #ffffff -background #d9d9d9 -anchor w -padx 0 -width 20 "

#ttk::button .fr1.fra82.fb1.b1  -command  {InitTok . .fr1.fra82.frl.labelframeinit;} -text " 1. Инициализация токена" -style My.TButton
set cmd "button .fr1.fra82.fb1.b1  -command  {InitTok . .fr1.fra82.frl.labelframeinit;} -text \" 1. Инициализация токена\" $borbut"
set cmd1 [subst $cmd]
eval $cmd1
pack .fr1.fra82.fb1.b1 -expand 1 -anchor center -fill x -side left -padx 5
#ttk::button .fr1.fra82.fb1.b2  -command {saveReq} -text " 2. Получить лицензию" -style My.TButton
set cmd "button .fr1.fra82.fb1.b2  -command {saveReq} -text \" 2. Получить лицензию\" $borbut"
set cmd1 [subst $cmd]
eval $cmd1
pack .fr1.fra82.fb1.b2 -expand 1 -anchor center -fill x -side right -padx 5
#ttk::button .fr1.fra82.fb2.b3 -command {saveLic} -text " 3. Установить лицензию" -style My.TButton
set cmd "button .fr1.fra82.fb2.b3 -command {saveLic} -text \" 3. Установить лицензию\"  $borbut"
set cmd1 [subst $cmd]
eval $cmd1
pack .fr1.fra82.fb2.b3 -expand 1  -anchor center -fill x -side left -padx 5
#ttk::button .fr1.fra82.fb2.b4 -command {createTar } -text " 4. Копия токена" -style My.TButton
set cmd "button .fr1.fra82.fb2.b4 -command {createTar } -text \" 4. Копия токена\" $borbut"
set cmd1 [subst $cmd]
eval $cmd1
pack .fr1.fra82.fb2.b4 -expand 1  -anchor center -fill x -side right -pady 3 -padx 5
#ttk::button .fr1.fra82.fb3.b5 -command {restoreTar} -text " 5. Восстановить токен" -style My.TButton
set cmd "button .fr1.fra82.fb3.b5 -command {restoreTar} -text \" 5. Восстановить токен\" $borbut"
set cmd1 [subst $cmd]
eval $cmd1
pack .fr1.fra82.fb3.b5 -expand 1 -anchor w -fill x -side left -padx 5
#ttk::button .fr1.fra82.fb3.b6 -command {infoToken $p11conf $libls11sw2016; } -text " 6. Статус токена" -style My.TButton
set cmd "button .fr1.fra82.fb3.b6 -command {infoToken $p11conf $libls11sw2016; } -text \" 6. Статус токена\" $borbut"
set cmd1 [subst $cmd]
eval $cmd1
pack .fr1.fra82.fb3.b6 -expand 1  -anchor center -fill x -side right -pady 3 -padx 5
ttk::button .fr1.fra82.b10 -text "  Мы все сделали  "  -image exitCA_16x16 -compound left -command {file delete -force  $pathutil; exit}

pack .fr1.fra82.frl.labelinit  -anchor center -expand 1 -pady 3 -side top

pack .fr1.fra82.b10 -expand 1 -anchor center -fill none -side bottom
pack .fr1.fra82.fb3 -anchor n -expand 1 -fill x -pady 1 -side bottom
pack .fr1.fra82.fb2 -anchor n -expand 1 -fill x -pady 1 -side bottom
pack .fr1.fra82.fb1 -anchor n -expand 1 -fill x -pady 1 -side bottom

pack .fr1.fra82.lstok -anchor center -expand 0 -fill both -ipadx 10 -ipady 0 -padx 5 -pady 0 -side bottom

#label .labMain -bg #39b5da -font {System 14 {bold roman}} -foreground #d90000 -text " Программный токен LS11SW2016" -image logoLSTok -compound left
label .labMain -bg #eff0f1 -font {System 14 {bold roman}} -foreground black -text " Программный токен LS11SW2016" -image logoLSTok -compound left
pack  .labMain -in .st  -side top -pady 5
pack .fr1 -in .st -side top -fill x
proc saveReq {} {
  global typesys
  global typesys1
  global pathtok
  global home
  global filereq
  global create_user_license_request

  #    set dirreq [tk_chooseDirectory  -title "Каталог для запроса на лицензию" -initialdir $home]
  set dirreq [tk_chooseDirectory  -title "Каталог для запроса на лицензию" -initialdir [file join $home ".LS11SW2016"]]
  if {$typesys1 == "win32" } {
    if { "after#" == [string range $dirreq 0 5] } {
      set dirreq ""
    }
  }
  if {$dirreq == ""} {
    set dirreq [file join $home ".LS11SW2016"]
    return
  }
  set tekdir [pwd]
  cd $pathtok
  catch {exec $create_user_license_request "LS11SW2016"}
  cd $tekdir
  set err [catch {file copy -force $filereq [file join $dirreq "LIC.REQ"]} res]
  if {$err} {
    tk_messageBox -title "Копирование запроса $filereq" \
    -icon error -message "Копирование не удалось.\nПроверьте каталог для копирования $dirreq"
    return
  }
  set filereq [file join $dirreq "LIC.REQ"]
  tk_messageBox -title "Копирование запроса" \
  -icon info -message "Запрос сохранен в файле:" -detail $filereq
  tk_messageBox -title "Получение лицензии на сайте" \
  -icon info -message "Сейчас перед вами появится Web-интерфейс." -detail "Следуйте его указаниям\n\
  Если браузер но умолчанию не запустился, то откройте сами следующую страницу\n\
  http://soft.lissi.ru/ls_product/LS11SW2016\nНапоминаем, запрос хранится в файле\n$filereq"
  if {$typesys != "windows" } {
    set browser $::env(BROWSER)
    exec $browser http://soft.lissi.ru/ls_product/LS11SW2016
  } else {
    exec {*}[auto_execok start] ""  "http://soft.lissi.ru/ls_product/LS11SW2016"
  }
}

proc saveLic {} {
  global pathtok
  global home
  global p11conf
  global libls11sw2016

  set filetype {
    {"Файл LIC.DAT с лицензией" "LIC.DAT"}
    {"Файл с лицензией" ".DAT"}
  }
  set newlic [tk_getOpenFile  -title "Выберите файл с лицензией токена" -initialdir $pathtok -filetypes $filetype]
  if {$newlic == ""} {
    return
  }
  set err [catch {file copy -force $newlic [file join $pathtok "LIC.DAT"]} res]
  if {$err} {
    tk_messageBox -title "Установка лицензии" \
    -icon error -message "Установить не удалось.\nПроверьте файл лицензии"
    return
  }
  tk_messageBox -title "Установка лицензии" \
  -icon info -message "Лицензия установлена:" -detail [file join $pathtok "LIC.DAT"]

  infoToken $p11conf $libls11sw2016
}

proc createTar {} {
  global pathtok
  global home
  global typesys1

  set tekdir [pwd]
  set dirtar [tk_chooseDirectory  -title "Выберите каталог для архива токена" -initialdir $home]
  if {$typesys1 == "win32" } {
    if { "after#" == [string range $dirtar 0 5] } {
      set dirtar ""
    }
  }
  if {$dirtar == ""} {
    return
  }
  cd $home
  set filetar [file join $dirtar "LS11SW2016.tar"]
  #    set err [catch {::tar::create $filetar $pathtok} res]
  set err [catch {::tar::create $filetar ".LS11SW2016"} res]
  cd $tekdir
  if {$err} {
    tk_messageBox -title "Архивирование токена" \
    -icon error -message "Архив не создан.\nПроверьте каталог для архива"
    return
  }
  tk_messageBox -title "Архивирование токена" \
  -icon info -message "Архив создан в файле:" -detail "$filetar"
}

proc restoreTar {} {
  global pathtok
  global home
  set filetype {
    {"Файл LS11SW2016.tar с копией" "LS11SW2016.tar"}
    {"Файл с копией" ".tar"}
  }
  set message "Приложения, работающие с токеном, должны быть заверщены.\nТекущий токен будет уничтожен!\nВосстановить токен?"
  set answer [tk_messageBox -icon question \
  -message $message \
  -parent .st \
  -title "Восстановление токена" \
  -type yesno]
  if {$answer != "yes"} {
    return
  }
  set filetar [tk_getOpenFile  -title "Выберите файл с архивом токена" -initialdir $home -filetypes $filetype]
  if {$filetar == ""} {
    return
  }
  catch {file delete -force $pathtok}
  set err [catch {::tar::untar $filetar -dir $home} res]
  if {$err} {
    tk_messageBox -title "Восстановление токена" \
    -icon error -message "Токен не восстановлен.\nПроверьте архив токена"
    return
  }
  tk_messageBox -title "Восстановление токена" \
  -icon info -message "Токен восстановлен в папке\n$pathtok"

}

proc statTok {command lib} {
  set err [catch {exec $command -A $lib -t} result]
  set cm [string first "Token not licensed" $result]
  if { $cm != -1} {
    #	tk_messageBox -title "Инициализация токена" \
    #	     -icon error -message "Нет лицензии на токен.\nНеобходимо получить лицензию"
    return -2
  }
  set cm [string first "CKF_USER_PIN_INITIALIZED" $result]
  if { $cm == -1} {
    #	tk_messageBox -title "Инициализация токена" \
    #	     -icon error -message "Токен не инициализирован.\nПроинициализируйте токен"
    return -1
  }
  return 0
}

proc infoToken {command lib} {
  global pathtok
  global home
  global create_user_license_request

  set err [catch {exec $command -A $lib -its -c 0} result]
  set cm [string first "Token not licensed" $result]
  if { $cm != -1} {
    set tekdir [pwd]
    cd $pathtok
    catch {exec $create_user_license_request "LS11SW2016"}
    cd $tekdir
    tk_messageBox -title "Информация о токене"   -icon info -message "Нет лицензии на токен ls11sw2016.\nНеобходимо получить и установить лицензию.\nНажмите кнопку \" 2. Получить лицензию\""
    return
  }
  set cm [string first "CKF_USER_PIN_INITIALIZED" $result]
  if { $cm == -1} {
    tk_messageBox -title "Информация о токене"   -icon info -message "Токен не инициализирован.\nПроинициализируйте токен"
    return
  }
  set date [dateLIC]
  tk_messageBox -title "Информация о токене"   -icon info -message "Токен в рабочем состоянии.\nЛицензия до $date" -detail $result -parent .
  return
}

proc dateLIC {} {
  global filelic

  if {[catch {set fl [open $filelic] } result]} {
    return ""
  }
  seek $fl 64 start
  set date [read $fl 8]
  close $fl
  set d [string range $date 0 1]
  set m [string range $date 2 3]
  set d [string range $date 0 1]
  set y [string range $date 4 end]
  return "$d.$m.$y"
}

proc statusTok {command} {
  puts "Status tokena=$command"
  set err [catch {exec $command auto_init_rng} result]
  return $result
}

#Создается болванка токена, если ее нет
set res [statusTok $create_sw_token]
#tk_messageBox -title "Инициализация токена"   -icon info -message $res
set res [statTok $p11conf $libls11sw2016]
switch -- $res {
  0        {
    set date [dateLIC]
    tk_messageBox -title "Инициализация токена"   -icon info -message "Токен готов к использованию.\nЛицензия до $date"
  }
  -1	{
    tk_messageBox -title "Инициализация токена"   -icon info -message "Токен не инициализирован.\nПроинициализируйте токен"
  }
  -2 - default {
    set tekdir [pwd]
    cd $pathtok
    catch {exec $create_user_license_request "LS11SW2016"}
    cd $tekdir
    set date [dateLIC]
    tk_messageBox -title "Информация о токене"   -icon info -message "Нет лицензии на токен." -detail "Запрос на лицензию хранится в :\n$filereq\nНеобходимо получить и установить лицензию.\nНажмите кнопку\n\"Получить лицензию\""
  }
}

proc InitTok { w createTok } {
  global p11conf
  global libls11sw2016
  global yespas
  global filereq
  set libpkcs11 $libls11sw2016
  set res [statTok $p11conf $libls11sw2016]
  if {$res == -2 } {
    tk_messageBox -title "Инициализация токена" -icon info -message "Инициализация токена невозможна.\nНет лицензии на токен." \
    -detail "Запрос на лицензию:\n$filereq\nНеобходимо получить и установить лицензию.\nНажмите кнопку\n\"Установить лицензию\""
    return
  }
  if {$res == 0 } {
    set yesno  [tk_messageBox -icon question -type yesno -title "Инициализация токена" -message "У вас есть Токен.\nХотите пересоздать токен?"]
    if {$yesno == "no"} {
      return
    }
  }

  pack forget .fr1.fra82.frl.labelinit
  pack .fr1.fra82.frl.labelframeinit  -anchor center -expand 1 -pady 5 -side top
  $createTok.entTok delete 0 end
  $createTok.entSoPin delete 0 end
  $createTok.entUserPin delete 0 end
  $createTok.entRepUserPin delete 0 end
  while {1} {
    set yespas ""
    vwait yespas
    #Ввод пароля
    if { $yespas == "no" } {
      pack forget .fr1.fra82.frl.labelframeinit
      pack .fr1.fra82.frl.labelinit  -anchor center -expand 1 -pady 3 -side top
      return
    }
    set pasUSER [$createTok.entUserPin get]
    set pasRepUSER [$createTok.entRepUserPin get]
    set nameTok [$createTok.entTok get]
    set pasSO [ $createTok.entSoPin get ]
    if {$pasRepUSER == "" || $pasUSER == "" || $nameTok == "" || $pasSO == "" } {
      tk_messageBox -title "Инициализация токена"  \
      -icon error -message "Не все поля заполнены"
      continue
    }
    if {$pasUSER != $pasRepUSER || [string length $pasRepUSER] < 4 || [string length $pasUSER] < 4} {
      tk_messageBox -title "Инициализация токена"  \
      -icon error -message "Ошибка в пароле пользователя"
      continue
    }
    break;
  }
  pack forget .fr1.fra82.frl.labelframeinit
  pack .fr1.fra82.frl.labelinit  -anchor center -expand 1 -pady 3 -side top

  #Initialize plus label Token
  set command "\"$p11conf\" -A \"$libpkcs11\"   -I -c 0 -S \"$pasSO\" -L \"$nameTok\""
  puts "$command"
  set tube [ open |$command r+]
  fconfigure $tube -buffering line
  	
  puts $tube $pasSO
  puts $tube $nameTok
  while {![eof $tube]} {
    gets $tube res
  }
  	
  if {[catch {close $tube} result]} {
    set substr "Token not licensed"
    set cm [string first $substr $result]
    if { $cm != -1} {
      tk_messageBox -title "Инициализация токена" \
      -icon error -message "Нет лицензии на токен $nameTok.\nНеобходимо получить лицензию"
      return
    }
    set substr "configure_default_slot failed"
    set cm [string first $substr $result]
    if { $cm != -1} {
      tk_messageBox -title "Инициализация токена" \
      -icon error -message "Нет токена.\nЕсли это программный токен, \n
      то повторите операцию"
      return
    }
    set substr "SO Pin Incorrect"
    set cm [string first $substr $result]
    if { $cm != -1} {
      tk_messageBox -title "Инициализация токена" \
      -icon error -message "Введен ошибочный SO-PIN.\nВы можете  повторить операцию."
      return
    }
    tk_messageBox -title "Инициализация токена" \
    -icon error -message "Ошибка доступа к  токену"
    return
  }
  #Initialize USER pin
  set command "\"$p11conf\" -A \"$libpkcs11\"  -u -c 0 -S \"$pasSO\" -n 11111111"
  puts "$command"
  set tube [ open |$command r+]
  fconfigure $tube -buffering line
  	
  while {![eof $tube]} {
    gets $tube res
  }
  if {[catch {close $tube} result]} {
    tk_messageBox -title "Инициализация токена" \
    -icon error -message "Ошибка инициализации пользовательского PIN-а"
    return
  }
  #Ustanavlivaem USER PIN
  set command "\"$p11conf\" -A \"$libpkcs11\"  -p -c 0 -U 11111111  -n \"$pasUSER\""
  puts "$command"
  set tube [ open |$command r+]
  fconfigure $tube -buffering line
  	
  while {![eof $tube]} {
    gets $tube res
  }
  	
  if {[catch {close $tube} result]} {
    tk_messageBox -title "Инициализация токена" \
    -icon error -message "Ошибка установки пользовательского PIN-а\nдля токена $nameTok"
    return
  }
  	
  tk_messageBox -title "Инициализация токена" \
  -icon info -message "Токен $nameTok успешно проинициализирован" \
  -detail "Никому не передавайте PIN от вашего токена.\n \
  Для смены PIN-кодов используйте утилиты cryptoarmpkcs"
  return
}

