# KBeacon ota tool 

allows over the air provisioning of all kbeacon pro beacons in the area.
provides a small UI to do some config,
and then deals with the connecting etc.

The configruation happens in SetAdvPeriodState.

it'll just start scanning after you press the button and configure
all the devices in the area to your desired advertisement interval.

should be able to easily modify this to any desired setting.


## Usage

1. make a build with android studio
2. launch it.
3. press grant permissions, accept, press it again untill it stops asking for them.
4. set your desired adv interval
4. press start scanning.


## Resources
most code is copied from:
https://github.com/kkmhogen/KBeaconProDemo_Android

(it was a bit haphazzard, this provides a full build).
