The following are sprites provided by flib for your use:

## Indicator sprites

![](https://raw.githubusercontent.com/factoriolib/flib/master/docs/assets/indicator-examples.png)

As seen above, indicator sprites are used to display the "status" of something. They are 16x16 in size, and are intended to be accompanied by a status label. The sprite names follow the `flib_indicator_COLOR` pattern, replacing `COLOR` with the corresponding color as shown in the preview above (e.g. `flib_indicator_blue`).

To align the indicator with an adjacent label, create both the indicator and label as children of a flow with the `flib_indicator_flow` style (see `gui-styles.md`).