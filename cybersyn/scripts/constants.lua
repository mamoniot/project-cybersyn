--By Mami

MISSING_TRAIN_NAME = "cybersyn-missing-train"
LOST_TRAIN_NAME = "cybersyn-lost-train"
NONEMPTY_TRAIN_NAME = "cybersyn-nonempty-train"

SIGNAL_PRIORITY = "cybersyn-priority"
REQUEST_THRESHOLD = "cybersyn-request-threshold"
LOCKED_SLOTS = "cybersyn-locked-slots"

COMBINATOR_NAME = "cybersyn-combinator"
COMBINATOR_OUT_NAME = "cybersyn-combinator-output"
COMBINATOR_CLOSE_SOUND = "entity-close/cybersyn-combinator"
ALERT_SOUND = "utility/console_message"

MODE_DEFAULT = "*"
MODE_PRIMARY_IO = "/"
MODE_PRIMARY_IO_FAILED_REQUEST = "^"
MODE_PRIMARY_IO_ACTIVE = "<<"
MODE_SECONDARY_IO = "%"
MODE_DEPOT = "+"
MODE_WAGON = "-"
MODE_REFUELER = ">>"

SETTING_DISABLE_ALLOW_LIST = 2
SETTING_IS_STACK = 3
SETTING_ENABLE_INACTIVE = 4
SETTING_USE_ANY_DEPOT = 5
SETTING_DISABLE_DEPOT_BYPASS = 6
SETTING_ENABLE_SLOT_BARRING = 7
SETTING_ENABLE_CIRCUIT_CONDITION = 8
SETTING_ENABLE_TRAIN_COUNT = 9
SETTING_ENABLE_MANUAL_INVENTORY = 10

NETWORK_SIGNAL_DEFAULT = { name = "signal-A", type = "virtual" }
NETWORK_SIGNAL_GUI_DEFAULT = { name = "signal-each", type = "virtual" }
NETWORK_ANYTHING = "signal-anything"
NETWORK_EACH = "signal-each"
INACTIVITY_TIME = 100
LOCK_TRAIN_TIME = 60 * 60 * 60 * 24 * 7

DELTA = 1 / 2048

DEPOT_PRIORITY_MULT = 2048

STATUS_D = 0
STATUS_TO_P = 1
STATUS_P = 2
STATUS_TO_R = 3
STATUS_R = 4
STATUS_TO_D = 5
STATUS_TO_D_BYPASS = 6
STATUS_TO_F = 7
STATUS_F = 8
STATUS_CUSTOM = 256 --this status and any status greater than it can be used by other mods (I've reserved the lower integers for myself in case I want to add more statuses)

LONGEST_INSERTER_REACH = 2

STATE_INIT = 0
STATE_POLL_STATIONS = 1
STATE_DISPATCH = 2

DIFFERENT_SURFACE_DISTANCE = 1000000000
