echo "usage: ./BUILD_BIN_GUICREATELSSW_FOR_LINUX.sh 32|64"
bb=$1
if [ ${bb:=0 } -eq 0   ]
    then 
	echo "Bad type 32|64"
	exit 1
fi
if [ $1 -ne 64  -a $1 -ne 32 ]
    then 
	echo "Bad type 32|64"
	exit 1
fi
a=LINUX32_WRAP664
cp -f create_sw_token_32 create_sw_token 
cp -f create_user_license_request_32 create_user_license_request
cp -f libls11sw2016_32.so libls11sw2016.so 
cp -f p11conf_32 p11conf

if [ "$1" -eq "64 " ]
    then 
	a=LINUX64_WRAP664
	cp -f create_sw_token_64 create_sw_token 
	cp -f create_user_license_request_64 create_user_license_request
	cp -f libls11sw2016_64.so libls11sw2016.so 
	cp -f p11conf_64 p11conf
	../../WRAP_MAC/tclexecomp64_v.1.0.3  guicreate_sw_tcl.tcl `cat LIST_UTIL_X86_64.txt` my_orel_380x150.png  -forcewrap -w ../../WRAP_MAC/tclexecomp64_v.1.0.3.linux -o guicreate_sw_token_linux_v.1.0.3
fi
echo $a

../../freewrap guicreate_sw_tcl.tcl `cat LIST_UTIL_X86_64.txt` my_orel_380x150.png  -w ../../$a/freewrap -o guicreate_sw_token_linux$1
chmod 755 guicreate_sw_token_linux$1
rm -f p11conf 
rm -f libls11sw2016.so
rm -f create_sw_token 
rm -f create_user_license_request
