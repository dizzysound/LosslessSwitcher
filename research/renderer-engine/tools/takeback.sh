L=~/Library/Logs/LosslessSwitcher-ExclusiveMode.log
M() { perl -e "alarm 15; exec @ARGV" osascript -e "tell application \"Music\" to $1"; }
waitfor() { local n=$1 pat=$2 t=$3; for i in $(seq 1 $t); do sed -n "$((n+1)),\$p" $L | grep -q "$pat" && return 0; sleep 1; done; return 1; }
for k in 1 2 3; do
  n=$(wc -l < $L); M "play (first track of library playlist 1 whose database ID is 90710)" >/dev/null
  waitfor $n "clock lock" 40; sleep 2; M pause >/dev/null
  n=$(wc -l < $L); waitfor $n "detached" 40
  n=$(wc -l < $L); M "play (first track of library playlist 1 whose name is \"Badlands\" and sample rate is 44100)" >/dev/null
  waitfor $n "clock lock" 40
  echo "== run $k: Music says $(M 'get sample rate of current track')"
  sed -n "$((n+1)),\$p" $L | grep "playback began\|resume\|new track\|switch [0-9]\|NOT ready\|rewound\|clock lock" | cut -c1-140
  sleep 3
done
M pause
