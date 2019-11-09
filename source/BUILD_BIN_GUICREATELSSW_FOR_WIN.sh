echo "usage: ./BUILD_BIN_GUICREATELSSW_FOR_WIN.sh 32|64"
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

a=WIN32_WRAP664
cp -f create_sw_token_32.exe create_sw_token.exe 
cp -f create_user_license_request_32.exe create_user_license_request.exe
cp -f ls11sw2016_32.dll ls11sw2016.dll
cp -f p11conf_32.exe p11conf.exe
if [ "$1" -eq "64 " ]
    then 
	a=WIN64_WRAP664
	cp -f create_sw_token_64.exe create_sw_token.exe 
	cp -f create_user_license_request_64.exe create_user_license_request.exe
	cp -f ls11sw2016_64.dll ls11sw2016.dll
	cp -f p11conf_64.exe p11conf.exe
fi
echo $a

iconv -f UTF-8 -t CP1251 guicreate_sw_tcl.tcl > guicreate_sw_tcl_CP1251.tcl

../../freewrap guicreate_sw_tcl_CP1251.tcl `cat LIST_UTIL_WIN32_64.txt` my_orel_380x150.png -i icon.ico -w ../../$a/freewrap.exe 
#/usr/local/bin64/freewrap GUITKP11Conf_COMBO_CP1251.tcl -w $1/freewrap.exe -i smart_32x32.ico
chmod 755 guicreate_sw_tcl_CP1251.exe
cp -f guicreate_sw_tcl_CP1251.exe guicreate_sw_token_win$1.exe
rm -f guicreate_sw_tcl_CP1251.exe
rm -f guicreate_sw_tcl_CP1251.tcl
rm -f ls11sw2016.dll
rm -f p11conf.exe
rm -f create_sw_token.exe
rm -f create_user_license_request.exe

