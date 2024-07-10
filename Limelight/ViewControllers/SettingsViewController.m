//
//  SettingsViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/27/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "SettingsViewController.h"
#import "TemporarySettings.h"
#import "DataManager.h"

#import <UIKit/UIGestureRecognizerSubclass.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>

#import "LocalizationHelper.h"

@implementation SettingsViewController {
    NSInteger _bitrate;
    NSInteger _lastSelectedResolutionIndex;
    bool justEnteredSettingsViewDoNotOpenOscLayoutTool;
}

@dynamic overrideUserInterfaceStyle;

//static NSString* bitrateFormat;
static const int bitrateTable[] = {
    500,
    1000,
    1500,
    2000,
    2500,
    3000,
    4000,
    5000,
    6000,
    7000,
    8000,
    9000,
    10000,
    12000,
    15000,
    18000,
    20000,
    30000,
    40000,
    50000,
    60000,
    70000,
    80000,
    100000,
    110000,
    120000,
    130000,
    140000,
    150000,
    160000,
    170000,
    180000,
    200000,
    220000,
    240000,
    260000,
    280000,
    300000,
    320000,
    340000,
    360000,
    380000,
    400000,
    420000,
    440000,
    460000,
    480000,
    500000,
};

const int RESOLUTION_TABLE_SIZE = 7;
const int RESOLUTION_TABLE_CUSTOM_INDEX = RESOLUTION_TABLE_SIZE - 1;
CGSize resolutionTable[RESOLUTION_TABLE_SIZE];

-(int)getSliderValueForBitrate:(NSInteger)bitrate {
    int i;
    
    for (i = 0; i < (sizeof(bitrateTable) / sizeof(*bitrateTable)); i++) {
        if (bitrate <= bitrateTable[i]) {
            return i;
        }
    }
    
    // Return the last entry in the table
    return i - 1;
}

// This view is rooted at a ScrollView. To make it scrollable,
// we'll update content size here.
-(void)viewDidLayoutSubviews {
    CGFloat highestViewY = 0;
    
    // Enumerate the scroll view's subviews looking for the
    // highest view Y value to set our scroll view's content
    // size.
    for (UIView* view in self.scrollView.subviews) {
        // UIScrollViews have 2 default child views
        // which represent the horizontal and vertical scrolling
        // indicators. Ignore any views we don't recognize.
        if (![view isKindOfClass:[UILabel class]] &&
            ![view isKindOfClass:[UISegmentedControl class]] &&
            ![view isKindOfClass:[UISlider class]]) {
            continue;
        }
        
        CGFloat currentViewY = view.frame.origin.y + view.frame.size.height;
        if (currentViewY > highestViewY) {
            highestViewY = currentViewY;
        }
    }
    
    // Add a bit of padding so the view doesn't end right at the button of the display
    self.scrollView.contentSize = CGSizeMake(self.scrollView.contentSize.width,
                                             highestViewY + 20);
}

// Adjust the subviews for the safe area on the iPhone X.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    
    if (@available(iOS 11.0, *)) {
        for (UIView* view in self.view.subviews) {
            // HACK: The official safe area is much too large for our purposes
            // so we'll just use the presence of any safe area to indicate we should
            // pad by 20.
            if (self.view.safeAreaInsets.left >= 20 || self.view.safeAreaInsets.right >= 20) {
                view.frame = CGRectMake(view.frame.origin.x + 20, view.frame.origin.y, view.frame.size.width, view.frame.size.height);
            }
        }
    }
}

BOOL isCustomResolution(CGSize res) {
    if (res.width == 0 && res.height == 0) {
        return NO;
    }
    
    for (int i = 0; i < RESOLUTION_TABLE_CUSTOM_INDEX; i++) {
        
        if ((res.width == resolutionTable[i].width && res.height == resolutionTable[i].height) || (res.height == resolutionTable[i].width && res.width == resolutionTable[i].height)) {
            return NO;
        }
    }
    
    return YES;
}

+ (bool)isLandscapeNow {
    return CGRectGetWidth([[UIScreen mainScreen]bounds]) > CGRectGetHeight([[UIScreen mainScreen]bounds]);
}

- (void)updateResolutionTable{
    UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
    CGFloat screenScale = window.screen.scale;
    CGFloat safeAreaWidth = (window.frame.size.width - window.safeAreaInsets.left - window.safeAreaInsets.right) * screenScale;
    CGFloat fullScreenWidth = window.frame.size.width * screenScale;
    CGFloat fullScreenHeight = window.frame.size.height * screenScale;
    
    resolutionTable[4] = CGSizeMake(safeAreaWidth, fullScreenHeight);
    resolutionTable[5] = CGSizeMake(fullScreenWidth, fullScreenHeight);

    for(uint8_t i=0;i<7;i++){
        CGFloat longSideLen = resolutionTable[i].height > resolutionTable[i].width ? resolutionTable[i].height : resolutionTable[i].width;
        CGFloat shortSideLen = resolutionTable[i].height < resolutionTable[i].width ? resolutionTable[i].height : resolutionTable[i].width;
        if([SettingsViewController isLandscapeNow]) resolutionTable[i] = CGSizeMake(longSideLen, shortSideLen);
        else resolutionTable[i] = CGSizeMake(shortSideLen, longSideLen);
    }
    
    [self updateResolutionDisplayViewText];
}

- (void)viewDidAppear:(BOOL)animated{
    [super viewDidAppear:animated];
    [self updateResolutionTable];
}

- (void)deviceOrientationDidChange{
    double delayInSeconds = 1.0;
    // Convert the delay into a dispatch_time_t value
    dispatch_time_t delayTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    // Perform some task after the delay
    dispatch_after(delayTime, dispatch_get_main_queue(), ^{
        // Code to execute after the delay
        NSLog(@"Resolution table to be updated");
        [self updateResolutionTable];
    });
}

- (void)simulateSettingsButtonPress{
    [self.mainFrameViewController simulateSettingsButtonPress];
}


- (void)viewDidDisappear:(BOOL)animated{
    [super viewDidDisappear:animated];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SettingsViewClosedNotification" object:self]; // notify other view that settings view just closed
}

- (void)pushDownExistingWidgets{
    // Calculate the height needed for the exit button
    CGFloat exitButtonHeight = 50.0; // Adjust as needed
    CGFloat topOffset = exitButtonHeight; // Space needed for the exit button
    // Iterate through subviews of self.view and adjust their frames
    for (UIView *subview in self.view.subviews) {
            CGRect frame = subview.frame;
            frame.origin.y += topOffset;
            subview.frame = frame;
    }
}


- (IBAction)exitButtonTapped:(id)sender {
    [self->_mainFrameViewController simulateSettingsButtonPress];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SessionDisconnectedBySettingsViewNotification" object:self];
}


- (void)addExitButtonOnTop{
    UIButton *exitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [exitButton setTitle:@"Exit" forState:UIControlStateNormal];
    [exitButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal]; // Set font color
    exitButton.backgroundColor = [UIColor clearColor]; // Set background color
    exitButton.titleLabel.font = [UIFont boldSystemFontOfSize:16.0]; // Set font size and style
    exitButton.layer.cornerRadius = 8.0; // Optional: Round corners if desired
    exitButton.clipsToBounds = YES; // Ensure rounded corners are applied properly
    [exitButton addTarget:self action:@selector(exitButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:exitButton];
    exitButton.frame = CGRectMake(0, 20, 200, 50); // Adjust Y and height as needed
}


- (void)viewDidLoad {
    //[self pushDownExistingWidgets];
    //[self addExitButtonOnTop];
    
    justEnteredSettingsViewDoNotOpenOscLayoutTool = true;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(deviceOrientationDidChange) // handle orientation change since i made portrait mode available
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    
    // for iphones that can not reach mainFrame, to register a gesture to simuluate setting button press & exit from setting view.
    _exitSwipeRecognizer = [[CustomEdgeSwipeGestureRecognizer alloc] initWithTarget:self action:@selector(simulateSettingsButtonPress)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft | UIRectEdgeRight;
    _exitSwipeRecognizer.normalizedThresholdDistance = 0;
    _exitSwipeRecognizer.edgeTolerancePoints = 5;
    _exitSwipeRecognizer.immediateTriggering = true;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
    
    // Always run settings in dark mode because we want the light fonts
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    
    // Ensure we pick a bitrate that falls exactly onto a slider notch
    _bitrate = bitrateTable[[self getSliderValueForBitrate:[currentSettings.bitrate intValue]]];

    // Get the size of the screen with and without safe area insets
    UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
    CGFloat screenScale = window.screen.scale;
    CGFloat safeAreaWidth = (window.frame.size.width - window.safeAreaInsets.left - window.safeAreaInsets.right) * screenScale;
    CGFloat fullScreenWidth = window.frame.size.width * screenScale;
    CGFloat fullScreenHeight = window.frame.size.height * screenScale;
    
    self.resolutionDisplayView.layer.cornerRadius = 10;
    self.resolutionDisplayView.clipsToBounds = YES;
    UITapGestureRecognizer *resolutionDisplayViewTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resolutionDisplayViewTapped:)];
    [self.resolutionDisplayView addGestureRecognizer:resolutionDisplayViewTap];
    
    resolutionTable[0] = CGSizeMake(640, 360);
    resolutionTable[1] = CGSizeMake(1280, 720);
    resolutionTable[2] = CGSizeMake(1920, 1080);
    resolutionTable[3] = CGSizeMake(3840, 2160);
    resolutionTable[4] = CGSizeMake(safeAreaWidth, fullScreenHeight);
    resolutionTable[5] = CGSizeMake(fullScreenWidth, fullScreenHeight);
    resolutionTable[6] = CGSizeMake([currentSettings.width integerValue], [currentSettings.height integerValue]); // custom initial value
    [self updateResolutionTable];
    
    // Don't populate the custom entry unless we have a custom resolution
    if (!isCustomResolution(resolutionTable[6])) {
        resolutionTable[6] = CGSizeMake(0, 0);
    }
    
    NSInteger framerate;
    switch ([currentSettings.framerate integerValue]) {
        case 30:
            framerate = 0;
            break;
        default:
        case 60:
            framerate = 1;
            break;
        case 120:
            framerate = 2;
            break;
    }

    NSInteger resolution = 1;
    for (int i = 0; i < RESOLUTION_TABLE_SIZE; i++) {
        if (((int) resolutionTable[i].height == [currentSettings.height intValue] && (int) resolutionTable[i].width == [currentSettings.width intValue]) || ((int) resolutionTable[i].width == [currentSettings.height intValue] && (int) resolutionTable[i].height == [currentSettings.width intValue])){
            resolution = i;
            break;
        }
    }    

    // Only show the 120 FPS option if we have a > 60-ish Hz display
    bool enable120Fps = false;
    if (@available(iOS 10.3, tvOS 10.3, *)) {
        if ([UIScreen mainScreen].maximumFramesPerSecond > 62) {
            enable120Fps = true;
        }
    }
    if (!enable120Fps) {
        [self.framerateSelector removeSegmentAtIndex:2 animated:NO];
    }

    // Disable codec selector segments for unsupported codecs
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
#endif
    {
        [self.codecSelector removeSegmentAtIndex:2 animated:NO];
    }
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        [self.codecSelector removeSegmentAtIndex:1 animated:NO];

        // Only enable the 4K option for "recent" devices. We'll judge that by whether
        // they support HEVC decoding (A9 or later).
        [self.resolutionSelector setEnabled:NO forSegmentAtIndex:3];
    }
    switch (currentSettings.preferredCodec) {
        case CODEC_PREF_AUTO:
            [self.codecSelector setSelectedSegmentIndex:self.codecSelector.numberOfSegments - 1];
            break;
            
        case CODEC_PREF_AV1:
            [self.codecSelector setSelectedSegmentIndex:2];
            break;
            
        case CODEC_PREF_HEVC:
            [self.codecSelector setSelectedSegmentIndex:1];
            break;
            
        case CODEC_PREF_H264:
            [self.codecSelector setSelectedSegmentIndex:0];
            break;
    }
    
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) || !(AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10)) {
        [self.hdrSelector removeAllSegments];
        [self.hdrSelector insertSegmentWithTitle:[LocalizationHelper localizedStringForKey:@"Unsupported on this device"] atIndex:0 animated:NO];
        [self.hdrSelector setEnabled:NO];
    }
    else {
        [self.hdrSelector setSelectedSegmentIndex:currentSettings.enableHdr ? 1 : 0];
    }
    
    [self.statsOverlaySelector setSelectedSegmentIndex:currentSettings.statsOverlay ? 1 : 0];
    [self.btMouseSelector setSelectedSegmentIndex:currentSettings.btMouseSupport ? 1 : 0];
    [self.optimizeSettingsSelector setSelectedSegmentIndex:currentSettings.optimizeGames ? 1 : 0];
    [self.framePacingSelector setSelectedSegmentIndex:currentSettings.useFramePacing ? 1 : 0];
    [self.multiControllerSelector setSelectedSegmentIndex:currentSettings.multiController ? 1 : 0];
    [self.swapABXYButtonsSelector setSelectedSegmentIndex:currentSettings.swapABXYButtons ? 1 : 0];
    [self.audioOnPCSelector setSelectedSegmentIndex:currentSettings.playAudioOnPC ? 1 : 0];
    _lastSelectedResolutionIndex = resolution;
    [self.resolutionSelector setSelectedSegmentIndex:resolution];
    [self.resolutionSelector addTarget:self action:@selector(newResolutionChosen) forControlEvents:UIControlEventValueChanged];
    [self.framerateSelector setSelectedSegmentIndex:framerate];
    [self.framerateSelector addTarget:self action:@selector(updateBitrate) forControlEvents:UIControlEventValueChanged];
    [self.bitrateSlider setMinimumValue:0];
    [self.bitrateSlider setMaximumValue:(sizeof(bitrateTable) / sizeof(*bitrateTable)) - 1];
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    [self.bitrateSlider addTarget:self action:@selector(bitrateSliderMoved) forControlEvents:UIControlEventValueChanged];
    [self updateBitrateText];
    [self updateResolutionDisplayViewText];
    
    // lift streamview setting
    [self.liftStreamViewForKeyboardSelector setSelectedSegmentIndex:currentSettings.liftStreamViewForKeyboard ? 1 : 0];// Load old setting
    
    // showkeyboard toolbar setting
    [self.showKeyboardToolbarSelector setSelectedSegmentIndex:currentSettings.showKeyboardToolbar ? 1 : 0];// Load old setting
    
    // swipe & exit setting
    [self.swipeExitScreenEdgeSelector setSelectedSegmentIndex:[self getSelectorIndexFromScreenEdge:(uint32_t)currentSettings.swipeExitScreenEdge.integerValue]]; // Load old setting
    [self.swipeToExitDistanceSlider setValue:currentSettings.swipeToExitDistance.floatValue];
    [self.swipeToExitDistanceSlider addTarget:self action:@selector(swipeToExitDistanceSliderMoved) forControlEvents:(UIControlEventValueChanged)]; // Update label display when slider is being moved.
    [self swipeToExitDistanceSliderMoved];
    

    
    //TouchMode & OSC Related Settings:
    
    // pointer veloc setting, will be enable/disabled by touchMode
    [self.pointerVelocityModeDividerSlider setValue:currentSettings.pointerVelocityModeDivider.floatValue * 100 animated:YES]; // Load old setting.
    [self.pointerVelocityModeDividerSlider addTarget:self action:@selector(pointerVelocityModeDividerSliderMoved) forControlEvents:(UIControlEventValueChanged)]; // Update label display when slider is being moved.
    [self pointerVelocityModeDividerSliderMoved];

    // init pointer veloc setting,  will be enable/disabled by touchMode
    [self.touchPointerVelocityFactorSlider setValue:currentSettings.touchPointerVelocityFactor.floatValue * 100 animated:YES]; // Load old setting.
    [self.touchPointerVelocityFactorSlider addTarget:self action:@selector(touchPointerVelocityFactorSliderMoved) forControlEvents:(UIControlEventValueChanged)]; // Update label display when slider is being moved.
    [self touchPointerVelocityFactorSliderMoved];
    
    // init relative touch mouse pointer veloc setting,  will be enable/disabled by touchMode
    [self.mousePointerVelocityFactorSlider setValue:currentSettings.mousePointerVelocityFactor.floatValue * 100 animated:YES]; // Load old setting.
    [self.mousePointerVelocityFactorSlider addTarget:self action:@selector(mousePointerVelocityFactorSliderMoved) forControlEvents:(UIControlEventValueChanged)]; // Update label display when slider is being moved.
    [self mousePointerVelocityFactorSliderMoved];
    
    
    // this setting will be affected by onscreenControl & touchMode, must be loaded before them.
    [self.keyboardToggleFingerNumSlider setValue:(CGFloat)currentSettings.keyboardToggleFingers.intValue animated:YES]; // Load old setting. old setting was converted to uint16_t before saving.
    [self.keyboardToggleFingerNumSlider addTarget:self action:@selector(keyboardToggleFingerNumSliderMoved) forControlEvents:(UIControlEventValueChanged)]; // Update label display when slider is being moved.
    [self keyboardToggleFingerNumSliderMoved];

    // this setting will be affected touchMode, must be loaded before them.
    NSInteger onscreenControlsLevel = [currentSettings.onscreenControls integerValue];
    [self.onscreenControlSelector setSelectedSegmentIndex:onscreenControlsLevel];
    [self.onscreenControlSelector addTarget:self action:@selector(onscreenControlChanged) forControlEvents:UIControlEventValueChanged];
    [self onscreenControlChanged];
    
    
    // [self.touchModeSelector setSelectedSegmentIndex:currentSettings.absoluteTouchMode ? 1 : 0];
    [self.touchModeSelector setSelectedSegmentIndex:currentSettings.touchMode.intValue]; //Load old touchMode setting
    [self.touchModeSelector addTarget:self action:@selector(touchModeChanged) forControlEvents:UIControlEventValueChanged];
    [self touchModeChanged];

    
    // init CustomOSC stuff
    /* sets a reference to the correct 'LayoutOnScreenControlsViewController' depending on whether the user is on an iPhone or iPad */
    self.layoutOnScreenControlsVC = [[LayoutOnScreenControlsViewController alloc] init];
    BOOL isIPhone = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    if (isIPhone) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"iPhone" bundle:nil];
        self.layoutOnScreenControlsVC = [storyboard instantiateViewControllerWithIdentifier:@"LayoutOnScreenControlsViewController"];
    }
    else {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"iPad" bundle:nil];
        self.layoutOnScreenControlsVC = [storyboard instantiateViewControllerWithIdentifier:@"LayoutOnScreenControlsViewController"];
        self.layoutOnScreenControlsVC.modalPresentationStyle = UIModalPresentationFullScreen;
    }
}


- (void)updateTouchModeLabel{
    NSString* labelText;
    switch([self.touchModeSelector selectedSegmentIndex]){
        case RELATIVE_TOUCH:
            labelText = [LocalizationHelper localizedStringForKey:@"Touch Mode - On Screen Game Controller Available"];break;
        case REGULAR_NATIVE_TOUCH:
            labelText = [LocalizationHelper localizedStringForKey:@"Touch Mode - With OSC & Mouse Support"];break;
        case PURE_NATIVE_TOUCH:
            labelText = [LocalizationHelper localizedStringForKey:@"Touch Mode - No OSC & Mouse Support"];break;
        case ABSOLUTE_TOUCH:
            labelText = [LocalizationHelper localizedStringForKey:@"Touch Mode - For MacOS Direct Touch"];break;
    }
    [self.touchModeLabel setText:labelText];
}


- (void)showCustomOSCTip {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@"Rebase in Stream View"]
                                                                             message:[LocalizationHelper localizedStringForKey:@"Tap 4 fingers to change on-screen controller layout in stream view"]
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey: @"Got it!"]
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction *action) {
                                                        // Continue execution after the alert is dismissed
                                                        if(!self->_mainFrameViewController.settingsExpandedInStreamView) [self invokeOscLayout]; //don't open osc layout tool immediately during streaming
                                                         NSLog(@"OK button tapped");
                                                     }];
    [alertController addAction:okAction];
    [self presentViewController:alertController animated:YES completion:nil];
}



- (void)onscreenControlChanged{
    
    BOOL isIPhone = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    if (isIPhone) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"iPhone" bundle:nil];
        self.layoutOnScreenControlsVC = [storyboard instantiateViewControllerWithIdentifier:@"LayoutOnScreenControlsViewController"];
    }
    else {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"iPad" bundle:nil];
        self.layoutOnScreenControlsVC = [storyboard instantiateViewControllerWithIdentifier:@"LayoutOnScreenControlsViewController"];
        self.layoutOnScreenControlsVC.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    
    bool oscEnabled = ([self.touchModeSelector selectedSegmentIndex] == RELATIVE_TOUCH || [self.touchModeSelector selectedSegmentIndex] == REGULAR_NATIVE_TOUCH) && [self.onscreenControlSelector selectedSegmentIndex] != OnScreenControlsLevelOff;
    bool customOscEnabled = oscEnabled && [self.onscreenControlSelector selectedSegmentIndex] == OnScreenControlsLevelCustom;
    [self widget:self.keyboardToggleFingerNumSlider setEnabled:!customOscEnabled];
    if(customOscEnabled && !justEnteredSettingsViewDoNotOpenOscLayoutTool) {
        [self.keyboardToggleFingerNumSlider setValue:3.0];
        [self keyboardToggleFingerNumSliderMoved];
        [self.onscreenControllerLabel setText:[LocalizationHelper localizedStringForKey: @"Tap 4 Fingers to Change OSC Layout in Stream View"]];
        [self showCustomOSCTip];
        justEnteredSettingsViewDoNotOpenOscLayoutTool = false;
        //if (self.layoutOnScreenControlsVC.isBeingPresented == NO)
    }
    else{
        [self.onscreenControllerLabel setText:[LocalizationHelper localizedStringForKey: @"On-Screen Controls"]];
    }
    justEnteredSettingsViewDoNotOpenOscLayoutTool = false;
}

- (void)invokeOscLayout{
    [self presentViewController:self.layoutOnScreenControlsVC animated:YES completion:nil];
}


- (void) pointerVelocityModeDividerSliderMoved {
    [self.pointerVelocityModeDividerUILabel setText:[LocalizationHelper localizedStringForKey:@"Touch Pointer Velocity: Scaled on %d%% of Right Screen", 100 - (uint8_t)self.pointerVelocityModeDividerSlider.value]];
}

- (void) touchPointerVelocityFactorSliderMoved {
    [self.touchPointerVelocityFactorUILabel setText:[LocalizationHelper localizedStringForKey: @"Touch Pointer Velocity: %d%%",  (uint16_t)self.touchPointerVelocityFactorSlider.value]]; // Update label display
}

- (void) mousePointerVelocityFactorSliderMoved {
    [self.mousePointerVelocityFactorUILabel setText:[LocalizationHelper localizedStringForKey: @"Mouse Pointer Velocity: %d%%",  (uint16_t)self.mousePointerVelocityFactorSlider.value]]; // Update label display
}

- (uint32_t) getScreenEdgeFromSelector {
    switch (self.swipeExitScreenEdgeSelector.selectedSegmentIndex) {
        case 0: return UIRectEdgeLeft;
        case 1: return UIRectEdgeRight;
        case 2: return UIRectEdgeLeft|UIRectEdgeRight;
        default: return UIRectEdgeLeft;
    }
}

- (uint32_t) getSelectorIndexFromScreenEdge: (uint32_t)edge {
    switch (edge) {
        case UIRectEdgeLeft: return 0;
        case UIRectEdgeRight: return 1;
        case UIRectEdgeLeft|UIRectEdgeRight: return 2;
        default: return 0;
    }
    return 0;
}

- (void) widget:(UISlider*)widget setEnabled:(bool)enabled{
    [widget setEnabled:enabled];
    if(enabled){
        widget.alpha = 1.0;
        [widget setValue:widget.value + 0.0001]; // this is for low iOS version (like iOS14), only setting this minor value change is able to make widget visibility clear
    }
    else widget.alpha = 0.5; // this is for updating widget visibility on low iOS version like mini5 ios14
}

- (void) touchModeChanged {
    // Disable on-screen controls in non-relative touch mode
    bool oscEnabled = ([self.touchModeSelector selectedSegmentIndex] == RELATIVE_TOUCH || [self.touchModeSelector selectedSegmentIndex] == REGULAR_NATIVE_TOUCH) && [self.onscreenControlSelector selectedSegmentIndex] != OnScreenControlsLevelOff;
    bool oscSelectorEnabled = [self.touchModeSelector selectedSegmentIndex] == RELATIVE_TOUCH || [self.touchModeSelector selectedSegmentIndex] == REGULAR_NATIVE_TOUCH;
    bool customOscEnabled = oscEnabled && [self.onscreenControlSelector selectedSegmentIndex] == OnScreenControlsLevelCustom;
    bool isNativeTouch = [self.touchModeSelector selectedSegmentIndex] == PURE_NATIVE_TOUCH || [self.touchModeSelector selectedSegmentIndex] == REGULAR_NATIVE_TOUCH;
    
    [self.onscreenControlSelector setEnabled:oscSelectorEnabled];
    
    [self widget:self.pointerVelocityModeDividerSlider setEnabled:isNativeTouch]; // pointer velocity scaling works only in native touch mode.
    [self widget:self.touchPointerVelocityFactorSlider setEnabled:isNativeTouch]; // pointer velocity scaling works only in native touch mode.
    [self widget:self.mousePointerVelocityFactorSlider setEnabled:[self.touchModeSelector selectedSegmentIndex] == RELATIVE_TOUCH]; // mouse velocity scaling works only in relative touch mode.
    
    // number of touches required to toggle keyboard will be fixed to 3 when OSC is enabled.
    [self widget:self.keyboardToggleFingerNumSlider setEnabled: !customOscEnabled];  // cancel OSC limitation for regular native touch,
    // when CustomOSC is enabled:
    if(customOscEnabled) {
        [self.keyboardToggleFingerNumSlider setValue:3.0];
        [self.keyboardToggleFingerNumLabel setText:[LocalizationHelper localizedStringForKey:@"To Toggle Local Keyboard: Tap %d Fingers", (uint16_t)self.keyboardToggleFingerNumSlider.value]];
        [self.onscreenControllerLabel setText:[LocalizationHelper localizedStringForKey: @"Tap 4 Fingers to Change OSC Layout in Stream View"]];
        //if (self.layoutOnScreenControlsVC.isBeingPresented == NO)
    }
    else{
        [self.onscreenControllerLabel setText:[LocalizationHelper localizedStringForKey: @"On-Screen Controls"]];
    }
    [self updateTouchModeLabel];
}

- (void) updateBitrate {
    NSInteger fps = [self getChosenFrameRate];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger defaultBitrate;
    
    // This logic is shamelessly stolen from Moonlight Qt:
    // https://github.com/moonlight-stream/moonlight-qt/blob/master/app/settings/streamingpreferences.cpp
    
    // Don't scale bitrate linearly beyond 60 FPS. It's definitely not a linear
    // bitrate increase for frame rate once we get to values that high.
    float frameRateFactor = (fps <= 60 ? fps : (sqrtf(fps / 60.f) * 60.f)) / 30.f;

    // TODO: Collect some empirical data to see if these defaults make sense.
    // We're just using the values that the Shield used, as we have for years.
    struct {
        NSInteger pixels;
        int factor;
    } resTable[] = {
        { 640 * 360, 1 },
        { 854 * 480, 2 },
        { 1280 * 720, 5 },
        { 1920 * 1080, 10 },
        { 2560 * 1440, 20 },
        { 3840 * 2160, 40 },
        { -1, -1 }
    };

    // Calculate the resolution factor by linear interpolation of the resolution table
    float resolutionFactor;
    NSInteger pixels = width * height;
    for (int i = 0;; i++) {
        if (pixels == resTable[i].pixels) {
            // We can bail immediately for exact matches
            resolutionFactor = resTable[i].factor;
            break;
        }
        else if (pixels < resTable[i].pixels) {
            if (i == 0) {
                // Never go below the lowest resolution entry
                resolutionFactor = resTable[i].factor;
            }
            else {
                // Interpolate between the entry greater than the chosen resolution (i) and the entry less than the chosen resolution (i-1)
                resolutionFactor = ((float)(pixels - resTable[i-1].pixels) / (resTable[i].pixels - resTable[i-1].pixels)) * (resTable[i].factor - resTable[i-1].factor) + resTable[i-1].factor;
            }
            break;
        }
        else if (resTable[i].pixels == -1) {
            // Never go above the highest resolution entry
            resolutionFactor = resTable[i-1].factor;
            break;
        }
    }

    defaultBitrate = round(resolutionFactor * frameRateFactor) * 1000;
    _bitrate = MIN(defaultBitrate, 100000);
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    
    [self updateBitrateText];
}

- (void) newResolutionChosen {
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        [self promptCustomResolutionDialog];
    }
    else {
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        _lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
    }
    [self updateResolutionTable];
}

- (void) promptCustomResolutionDialog {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey: @"Enter Custom Resolution"] message:nil preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Video Width"];
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width];
        }
    }];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = [LocalizationHelper localizedStringForKey:@"Video Height"];
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height];
        }
    }];

    [alertController addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray * textfields = alertController.textFields;
        UITextField *widthField = textfields[0];
        UITextField *heightField = textfields[1];
        
        long width = [widthField.text integerValue];
        long height = [heightField.text integerValue];
        if (width <= 0 || height <= 0) {
            // Restore the previous selection
            [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
            return;
        }
        
        // H.264 maximum
        int maxResolutionDimension = 4096;
        if (@available(iOS 11.0, tvOS 11.0, *)) {
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                // HEVC maximum
                maxResolutionDimension = 8192;
            }
        }
        
        // Cap to maximum valid dimensions
        width = MIN(width, maxResolutionDimension);
        height = MIN(height, maxResolutionDimension);
        
        // Cap to minimum valid dimensions
        width = MAX(width, 256);
        height = MAX(height, 256);

        resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX] = CGSizeMake(width, height);
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        self->_lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
        
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[LocalizationHelper localizedStringForKey:@"Custom Resolution Selected"] message: [LocalizationHelper localizedStringForKey:@"Custom resolutions are not officially supported by GeForce Experience, so it will not set your host display resolution. You will need to set it manually while in game.\n\nResolutions that are not supported by your client or host PC may cause streaming errors."] preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Ok"] style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:[LocalizationHelper localizedStringForKey:@"Cancel"] style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        // Restore the previous selection
        [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
    }]];

    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)resolutionDisplayViewTapped:(UITapGestureRecognizer *)sender {
    NSURL *url = [NSURL URLWithString:@"https://moonlight-stream.org/custom-resolution"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void) updateResolutionDisplayViewText {
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    CGFloat viewFrameWidth = self.resolutionDisplayView.frame.size.width;
    CGFloat viewFrameHeight = self.resolutionDisplayView.frame.size.height;
    CGFloat padding = 10;
    CGFloat fontSize = [UIFont smallSystemFontSize];
    
    for (UIView *subview in self.resolutionDisplayView.subviews) {
        [subview removeFromSuperview];
    }
    UILabel *label1 = [[UILabel alloc] init];
    label1.text = [LocalizationHelper localizedStringForKey:@"Set PC/Game resolution:"];
    label1.font = [UIFont systemFontOfSize:fontSize];
    [label1 sizeToFit];
    label1.frame = CGRectMake(padding, (viewFrameHeight - label1.frame.size.height) / 2, label1.frame.size.width, label1.frame.size.height);

    UILabel *label2 = [[UILabel alloc] init];
    label2.text = [NSString stringWithFormat:@"%ld x %ld", (long)width, (long)height];
    [label2 sizeToFit];
    label2.frame = CGRectMake(viewFrameWidth - label2.frame.size.width - padding, (viewFrameHeight - label2.frame.size.height) / 2, label2.frame.size.width, label2.frame.size.height);

    [self.resolutionDisplayView addSubview:label1];
    [self.resolutionDisplayView addSubview:label2];
}

- (void) keyboardToggleFingerNumSliderMoved{
    if (self.keyboardToggleFingerNumSlider.value > 10.5f) [self.keyboardToggleFingerNumLabel setText:[LocalizationHelper localizedStringForKey:@"Local Keyboard Toggle Disabled"]];
    else [self.keyboardToggleFingerNumLabel setText:[LocalizationHelper localizedStringForKey:@"To Toggle Local Keyboard: Tap %d Fingers", (uint16_t)self.keyboardToggleFingerNumSlider.value]]; // Initiate label display
}

- (void) swipeToExitDistanceSliderMoved{
    [self.swipeToExitDistanceUILabel setText:[LocalizationHelper localizedStringForKey:@"Swipe & Exit Distance: %.2f * screen-width", self.swipeToExitDistanceSlider.value]];
}

- (void) bitrateSliderMoved {
    assert(self.bitrateSlider.value < (sizeof(bitrateTable) / sizeof(*bitrateTable)));
    _bitrate = bitrateTable[(int)self.bitrateSlider.value];
    [self updateBitrateText];
}

- (void) updateBitrateText {
    // Display bitrate in Mbps
    [self.bitrateLabel setText:[LocalizationHelper localizedStringForKey:@"Bitrate: %.1f Mbps", _bitrate / 1000.]];
}

- (NSInteger) getChosenFrameRate {
    switch ([self.framerateSelector selectedSegmentIndex]) {
        case 0:
            return 30;
        case 1:
            return 60;
        case 2:
            return 120;
        default:
            abort();
    }
}

- (uint32_t) getChosenCodecPreference {
    // Auto is always the last segment
    if (self.codecSelector.selectedSegmentIndex == self.codecSelector.numberOfSegments - 1) {
        return CODEC_PREF_AUTO;
    }
    else {
        switch (self.codecSelector.selectedSegmentIndex) {
            case 0:
                return CODEC_PREF_H264;
                
            case 1:
                return CODEC_PREF_HEVC;
                
            case 2:
                return CODEC_PREF_AV1;
                
            default:
                abort();
        }
    }
}

- (NSInteger) getChosenStreamHeight {
    // because the 4k resolution can be removed
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        return resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height;
    }

    return resolutionTable[[self.resolutionSelector selectedSegmentIndex]].height;
}

- (NSInteger) getChosenStreamWidth {
    // because the 4k resolution can be removed
    BOOL lastSegmentSelected = [self.resolutionSelector selectedSegmentIndex] + 1 == [self.resolutionSelector numberOfSegments];
    if (lastSegmentSelected) {
        return resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width;
    }

    return resolutionTable[[self.resolutionSelector selectedSegmentIndex]].width;
}

- (void) saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger framerate = [self getChosenFrameRate];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger onscreenControls = [self.onscreenControlSelector selectedSegmentIndex];
    NSInteger keyboardToggleFingers = (uint16_t)self.keyboardToggleFingerNumSlider.value;
    // NSLog(@"saveSettings keyboardToggleFingers  %d", (uint16_t)keyboardToggleFingers);
    CGFloat swipeToExitDistance = self.swipeToExitDistanceSlider.value;
    uint32_t swipeExitScreenEdge = [self getScreenEdgeFromSelector];
    CGFloat pointerVelocityModeDivider = (CGFloat)(uint8_t)self.pointerVelocityModeDividerSlider.value/100;
    CGFloat touchPointerVelocityFactor =(CGFloat)(uint16_t)self.touchPointerVelocityFactorSlider.value/100;
    CGFloat mousePointerVelocityFactor =(CGFloat)(uint16_t)self.mousePointerVelocityFactorSlider.value/100;
    BOOL liftStreamViewForKeyboard = [self.liftStreamViewForKeyboardSelector selectedSegmentIndex] == 1;
    BOOL showKeyboardToolbar = [self.showKeyboardToolbarSelector selectedSegmentIndex] == 1;
    BOOL optimizeGames = [self.optimizeSettingsSelector selectedSegmentIndex] == 1;
    BOOL multiController = [self.multiControllerSelector selectedSegmentIndex] == 1;
    BOOL swapABXYButtons = [self.swapABXYButtonsSelector selectedSegmentIndex] == 1;
    BOOL audioOnPC = [self.audioOnPCSelector selectedSegmentIndex] == 1;
    uint32_t preferredCodec = [self getChosenCodecPreference];
    BOOL btMouseSupport = [self.btMouseSelector selectedSegmentIndex] == 1;
    BOOL useFramePacing = [self.framePacingSelector selectedSegmentIndex] == 1;
    // BOOL absoluteTouchMode = [self.touchModeSelector selectedSegmentIndex] == 1;
    NSInteger touchMode = [self.touchModeSelector selectedSegmentIndex];
    BOOL statsOverlay = [self.statsOverlaySelector selectedSegmentIndex] == 1;
    BOOL enableHdr = [self.hdrSelector selectedSegmentIndex] == 1;
    [dataMan saveSettingsWithBitrate:_bitrate
                           framerate:framerate
                              height:height
                               width:width
                         audioConfig:2 // Stereo
                    onscreenControls:onscreenControls
               keyboardToggleFingers:keyboardToggleFingers
                 swipeExitScreenEdge:swipeExitScreenEdge
                 swipeToExitDistance:swipeToExitDistance
          pointerVelocityModeDivider:pointerVelocityModeDivider
          touchPointerVelocityFactor:touchPointerVelocityFactor
          mousePointerVelocityFactor:mousePointerVelocityFactor
           liftStreamViewForKeyboard:liftStreamViewForKeyboard
                 showKeyboardToolbar:showKeyboardToolbar
                       optimizeGames:optimizeGames
                     multiController:multiController
                     swapABXYButtons:swapABXYButtons
                           audioOnPC:audioOnPC
                      preferredCodec:preferredCodec
                      useFramePacing:useFramePacing
                           enableHdr:enableHdr
                      btMouseSupport:btMouseSupport
                   // absoluteTouchMode:absoluteTouchMode
                           touchMode:touchMode
                        statsOverlay:statsOverlay];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
}


@end
