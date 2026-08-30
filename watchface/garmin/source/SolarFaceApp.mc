using Toybox.Application;
using Toybox.WatchUi;

class SolarFaceApp extends Application.AppBase {

    hidden var mView;

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        mView = new SolarFaceView();
        return [mView];
    }

    //! Fires when settings change on the phone or in Garmin Express.
    function onSettingsChanged() {
        if (mView != null) {
            mView.loadSettings();
            WatchUi.requestUpdate();
        }
    }
}
