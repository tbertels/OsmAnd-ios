//
//  OAMapPanelViewController.m
//  OsmAnd
//
//  Created by Alexey Pelykh on 8/20/13.
//  Copyright (c) 2013 OsmAnd. All rights reserved.
//

#import "OAMapPanelViewController.h"

#import "OsmAndApp.h"
#import "UIViewController+OARootViewController.h"
#import "OABrowseMapAppModeHudViewController.h"
#import "OADriveAppModeHudViewController.h"
#import "OAMapViewController.h"
#import "OAAutoObserverProxy.h"
#import "OALog.h"
#import "OAIAPHelper.h"
#import "OAGPXItemViewController.h"

#import <EventKit/EventKit.h>

#import "OAMapRendererView.h"
#import "OANativeUtilities.h"
#import "OADestinationViewController.h"
#import "OADestination.h"
#import "OAMapSettingsViewController.h"
#import "OAPOISearchViewController.h"
#import "OAPOIType.h"
#import "OADefaultFavorite.h"
#import "OATargetPoint.h"
#import "Localization.h"
#import "InfoWidgetsView.h"
#import "OAAppSettings.h"
#import "OASavingTrackHelper.h"
#import "PXAlertView.h"
#import "OATrackIntervalDialogView.h"
#import "OASetParkingViewController.h"

#import <UIAlertView+Blocks.h>
#import <UIAlertView-Blocks/RIButtonItem.h>

#include <OsmAndCore.h>
#include <OsmAndCore/Utilities.h>
#include <OsmAndCore/Data/Road.h>
#include <OsmAndCore/CachingRoadLocator.h>
#include <OsmAndCore/IFavoriteLocation.h>
#include <OsmAndCore/IFavoriteLocationsCollection.h>


#define _(name) OAMapPanelViewController__##name
#define commonInit _(commonInit)
#define deinit _(deinit)

#define kMaxRoadDistanceInMeters 1000

@interface OAMapPanelViewController () <OADestinationViewControllerProtocol, InfoWidgetsViewDelegate, OASetParkingDelegate>

@property (nonatomic) OABrowseMapAppModeHudViewController *browseMapViewController;
@property (nonatomic) OADriveAppModeHudViewController *driveModeViewController;
@property (nonatomic) OADestinationViewController *destinationViewController;
@property (nonatomic) InfoWidgetsView *widgetsView;

@property (strong, nonatomic) OATargetPointView* targetMenuView;
@property (strong, nonatomic) UIButton* shadowButton;

@property (nonatomic, strong) UIViewController* prevHudViewController;

@end

@implementation OAMapPanelViewController
{
    OsmAndAppInstance _app;
    OAAppSettings *_settings;
    OASavingTrackHelper *_recHelper;

    OAAutoObserverProxy* _appModeObserver;
    OAAutoObserverProxy* _addonsSwitchObserver;

    BOOL _hudInvalidated;
    
    BOOL _mapNeedsRestore;
    OAMapMode _mainMapMode;
    OsmAnd::PointI _mainMapTarget31;
    float _mainMapZoom;
    float _mainMapAzimuth;
    float _mainMapEvelationAngle;
    
    NSString *_formattedTargetName;
    double _targetLatitude;
    double _targetLongitude;

    OAMapSettingsViewController *_mapSettings;
    OAPOISearchViewController *_searchPOI;
    UILongPressGestureRecognizer *_shadowLongPress;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit
{
    _app = [OsmAndApp instance];

    _settings = [OAAppSettings sharedManager];
    _recHelper = [OASavingTrackHelper sharedInstance];

    _appModeObserver = [[OAAutoObserverProxy alloc] initWith:self
                                                 withHandler:@selector(onAppModeChanged)
                                                  andObserve:_app.appModeObservable];
    
    _addonsSwitchObserver = [[OAAutoObserverProxy alloc] initWith:self
                                                      withHandler:@selector(onAddonsSwitch:withKey:andValue:)
                                                       andObserve:_app.addonsSwitchObservable];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onTargetPointSet:) name:kNotificationSetTargetPoint object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onNoSymbolFound:) name:kNotificationNoSymbolFound object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onContextMarkerClicked:) name:kNotificationContextMarkerClicked object:nil];

    _hudInvalidated = NO;
}

- (void)loadView
{
    OALog(@"Creating Map Panel views...");
    
    // Create root view
    UIView* rootView = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view = rootView;
    
    // Instantiate map view controller
    _mapViewController = [[OAMapViewController alloc] init];
    [self addChildViewController:_mapViewController];
    [self.view addSubview:_mapViewController.view];
    _mapViewController.view.frame = self.view.frame;
    _mapViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // Setup target point menu
    self.targetMenuView = [[OATargetPointView alloc] initWithFrame:CGRectMake(0.0, 0.0, DeviceScreenWidth, kOATargetPointViewHeightPortrait)];
    self.targetMenuView.delegate = self;

    _widgetsView = [[InfoWidgetsView alloc] init];
    _widgetsView.delegate = self;
    
    [self updateHUD:NO];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [_widgetsView updateGpxRec];

    if (_hudInvalidated)
    {
        [self updateHUD:animated];
        _hudInvalidated = NO;
    }
    
    if (_mapNeedsRestore) {
        _mapNeedsRestore = NO;
        [self restoreMapAfterReuse];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    if ([_mapViewController parentViewController] != self)
        [self doMapRestore];
}

- (void)viewWillLayoutSubviews
{
    if (_destinationViewController)
        [_destinationViewController updateFrame:YES];
    
    if (_shadowButton)
        _shadowButton.frame = [self shadowButtonRect];
}
 
@synthesize mapViewController = _mapViewController;
@synthesize hudViewController = _hudViewController;

- (void) infoSelectPressed
{
    BOOL recOn = _settings.mapSettingTrackRecording;

    if (recOn)
    {
        
        [PXAlertView showAlertWithTitle:OALocalizedString(@"track_recording")
                                                     message:nil
                                                 cancelTitle:OALocalizedString(@"shared_string_cancel")
                                                 otherTitles:@[ OALocalizedString(@"track_stop_rec"), OALocalizedString(@"show_info"), OALocalizedString(@"track_new_segment"), OALocalizedString(@"track_save") ]
                                                 otherImages:@[@"track_recording_stop.png", @"icon_info.png", @"track_new_segement.png" , @"track_save.png"]
                                                  completion:^(BOOL cancelled, NSInteger buttonIndex) {
                                                      if (!cancelled) {
                                                          switch (buttonIndex) {
                                                              case 0:
                                                              {
                                                                  _settings.mapSettingTrackRecording = NO;
                                                                  break;
                                                              }
                                                              case 1:
                                                              {
                                                                  OAGPXItemViewController* controller = [[OAGPXItemViewController alloc] initWithCurrentGPXItemNoToolbar];
                                                                  [self.navigationController pushViewController:controller animated:YES];
                                                                  break;
                                                              }
                                                              case 2:
                                                              {
                                                                  [_recHelper startNewSegment];
                                                                  break;
                                                              }
                                                              case 3:
                                                              {
                                                                  if ([_recHelper hasDataToSave] && _recHelper.distance < 10.0)
                                                                  {
                                                                      [PXAlertView showAlertWithTitle:OALocalizedString(@"track_save_short_q")
                                                                                              message:nil
                                                                                          cancelTitle:OALocalizedString(@"shared_string_no")
                                                                                           otherTitle:OALocalizedString(@"shared_string_yes")
                                                                                           otherImage:nil
                                                                                           completion:^(BOOL cancelled, NSInteger buttonIndex) {
                                                                                               if (!cancelled) {
                                                                                                   _settings.mapSettingTrackRecording = NO;
                                                                                                   [self saveTrack:YES];
                                                                                               }
                                                                                           }];
                                                                  }
                                                                  else
                                                                  {
                                                                      _settings.mapSettingTrackRecording = NO;
                                                                      [self saveTrack:YES];
                                                                  }
                                                                  break;
                                                              }
                                                              default:
                                                                  break;
                                                          }
                                                      }
                                                  }];

    }
    else
    {
        if ([_recHelper hasData])
        {
            [PXAlertView showAlertWithTitle:OALocalizedString(@"track_recording")
                                    message:nil
                                cancelTitle:OALocalizedString(@"shared_string_cancel")
                                 otherTitles:@[OALocalizedString(@"track_continue_rec"), OALocalizedString(@"show_info"), OALocalizedString(@"track_clear"), OALocalizedString(@"track_save")]
                                otherImages:@[@"ic_action_rec_start.png", @"icon_info.png", @"track_clear_data.png", @"track_save.png"]
                                 completion:^(BOOL cancelled, NSInteger buttonIndex) {
                                     if (!cancelled) {
                                         switch (buttonIndex) {
                                             case 0:
                                             {
                                                 [_recHelper startNewSegment];
                                                 _settings.mapSettingTrackRecording = YES;
                                                 break;
                                             }
                                             case 1:
                                             {
                                                 OAGPXItemViewController* controller = [[OAGPXItemViewController alloc] initWithCurrentGPXItemNoToolbar];
                                                 [self.navigationController pushViewController:controller animated:YES];
                                                 break;
                                             }
                                             case 2:
                                             {
                                                 [PXAlertView showAlertWithTitle:OALocalizedString(@"track_clear_q")
                                                                         message:nil
                                                                     cancelTitle:OALocalizedString(@"shared_string_no")
                                                                      otherTitle:OALocalizedString(@"shared_string_yes")
                                                                      otherImage:nil
                                                                      completion:^(BOOL cancelled, NSInteger buttonIndex) {
                                                                          if (!cancelled)
                                                                          {
                                                                              [_recHelper clearData];
                                                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                                                  [_mapViewController hideRecGpxTrack];
                                                                                  [_widgetsView updateGpxRec];
                                                                              });
                                                                          }
                                                                      }];
                                                 break;
                                             }
                                             case 3:
                                             {
                                                 if ([_recHelper hasDataToSave] && _recHelper.distance < 10.0)
                                                 {
                                                     [PXAlertView showAlertWithTitle:OALocalizedString(@"track_save_short_q")
                                                                             message:nil
                                                                         cancelTitle:OALocalizedString(@"shared_string_no")
                                                                          otherTitle:OALocalizedString(@"shared_string_yes")
                                                                          otherImage:nil
                                                                          completion:^(BOOL cancelled, NSInteger buttonIndex) {
                                                                              if (!cancelled) {
                                                                                  [self saveTrack:NO];
                                                                              }
                                                                          }];
                                                 }
                                                 else
                                                 {
                                                     [self saveTrack:NO];
                                                 }
                                                 break;
                                             }
                                                 
                                             default:
                                                 break;
                                         }
                                     }
                                 }];
        }
        else
        {
            if (!_settings.mapSettingSaveTrackIntervalApproved)
            {
                OATrackIntervalDialogView *view = [[OATrackIntervalDialogView alloc] initWithFrame:CGRectMake(0.0, 0.0, 252.0, 116.0)];
                
                [PXAlertView showAlertWithTitle:OALocalizedString(@"track_start_rec")
                                        message:nil
                                    cancelTitle:OALocalizedString(@"shared_string_cancel")
                                     otherTitle:OALocalizedString(@"shared_string_ok")
                                     otherImage:nil
                                    contentView:view
                                     completion:^(BOOL cancelled, NSInteger buttonIndex) {
                                         
                                         if (!cancelled)
                                         {
                                             _settings.mapSettingSaveTrackIntervalGlobal = [_settings.trackIntervalArray[[view getInterval]] intValue];
                                             if (view.swRemember.isOn)
                                                 _settings.mapSettingSaveTrackIntervalApproved = YES;

                                             _settings.mapSettingTrackRecording = YES;
                                         }
                                     }];
            }
            else
            {
                _settings.mapSettingTrackRecording = YES;
            }
            
        }
    }
}

- (void) saveTrack:(BOOL)askForRec
{
    if ([_recHelper hasDataToSave])
        [_recHelper saveDataToGpx];
    dispatch_async(dispatch_get_main_queue(), ^{
        [_widgetsView updateGpxRec];
    });
    
    if (askForRec)
    {
        [PXAlertView showAlertWithTitle:OALocalizedString(@"track_continue_rec_q")
                                message:nil
                            cancelTitle:OALocalizedString(@"shared_string_no")
                             otherTitle:OALocalizedString(@"shared_string_yes")
                             otherImage:nil
                             completion:^(BOOL cancelled, NSInteger buttonIndex) {
                                 if (!cancelled) {
                                     _settings.mapSettingTrackRecording = YES;
                                     
                                 }
                             }];
    }
}

- (void)updateHUD:(BOOL)animated
{
    if (!_destinationViewController) {
        _destinationViewController = [[OADestinationViewController alloc] initWithNibName:@"OADestinationViewController" bundle:nil];
        _destinationViewController.delegate = self;

        for (OADestination *destination in _app.data.destinations)
            [_mapViewController addDestinationPin:destination.markerResourceName color:destination.color latitude:destination.latitude longitude:destination.longitude];

    }
    
    // Inflate new HUD controller and add it
    UIViewController* newHudController = nil;
    if (_app.appMode == OAAppModeBrowseMap)
    {
        if (!self.browseMapViewController) {
            self.browseMapViewController = [[OABrowseMapAppModeHudViewController alloc] initWithNibName:@"BrowseMapAppModeHUD"
                                                                                   bundle:nil];
            _browseMapViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            _browseMapViewController.destinationViewController = self.destinationViewController;
            if ([[OAIAPHelper sharedInstance] productPurchased:kInAppId_Addon_TrackRecording])
                _browseMapViewController.widgetsView = self.widgetsView;
            else
                _browseMapViewController.widgetsView = nil;
            
        }
        
        newHudController = self.browseMapViewController;

        _mapViewController.view.frame = self.view.frame;
    }
    else if (_app.appMode == OAAppModeDrive)
    {
        if (!self.driveModeViewController) {
            self.driveModeViewController = [[OADriveAppModeHudViewController alloc] initWithNibName:@"DriveAppModeHUD"
                                                                               bundle:nil];
            _driveModeViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            _driveModeViewController.destinationViewController = self.destinationViewController;
            if ([[OAIAPHelper sharedInstance] productPurchased:kInAppId_Addon_TrackRecording])
                _driveModeViewController.widgetsView = self.widgetsView;
            else
                _driveModeViewController.widgetsView = nil;
        }

        newHudController = self.driveModeViewController;
        
        CGRect frame = self.view.frame;
        frame.origin.y = 64.0;
        frame.size.height = DeviceScreenHeight - 64.0;
        _mapViewController.view.frame = frame;

    }
    [self addChildViewController:newHudController];

    // Switch views
    newHudController.view.frame = self.view.frame;
    [self.view addSubview:newHudController.view];
    
    if (animated && _hudViewController != nil)
    {
        _prevHudViewController = _hudViewController;
        [UIView transitionFromView:_hudViewController.view
                            toView:newHudController.view
                          duration:0.6
                           options:UIViewAnimationOptionTransitionFlipFromTop
         
                        completion:^(BOOL finished) {
                            [_prevHudViewController.view removeFromSuperview];
                            _prevHudViewController = nil;
                        }];
    }
    else
    {
        if (_hudViewController != nil)
            [_hudViewController.view removeFromSuperview];
    }

    // Remove previous view controller if such exists
    if (_hudViewController != nil)
        [_hudViewController removeFromParentViewController];
    _hudViewController = newHudController;
    
    [_destinationViewController updateFrame:NO];

    [self.rootViewController setNeedsStatusBarAppearanceUpdate];
}

- (void)updateOverlayUnderlayView:(BOOL)show
{
    if (self.browseMapViewController)
        [_browseMapViewController updateOverlayUnderlayView:show];
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    if (_hudViewController == nil)
        return UIStatusBarStyleDefault;

    return _hudViewController.preferredStatusBarStyle;
}

- (void)onAppModeChanged
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isViewLoaded || self.view.window == nil)
        {
            _hudInvalidated = YES;
            return;
        }

        [self updateHUD:YES];
    });
}

- (void)onAddonsSwitch:(id)observable withKey:(id)key andValue:(id)value
{
    NSString *productIdentifier = key;
    if ([productIdentifier isEqualToString:kInAppId_Addon_TrackRecording])
    {
        BOOL active = [value boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            
            if (!active)
            {
                _settings.mapSettingTrackRecording = NO;

                if ([_recHelper hasDataToSave])
                    [_recHelper saveDataToGpx];

                [_mapViewController hideRecGpxTrack];
                
                if (self.browseMapViewController)
                    _browseMapViewController.widgetsView = nil;
                if (self.driveModeViewController)
                    _driveModeViewController.widgetsView = nil;
                [self.widgetsView removeFromSuperview];
            }
            else
            {
                if (_app.appMode == OAAppModeBrowseMap)
                {
                    if (self.browseMapViewController)
                        _browseMapViewController.widgetsView = self.widgetsView;
                }
                else if (_app.appMode == OAAppModeDrive)
                {
                    if (self.driveModeViewController)
                        _driveModeViewController.widgetsView = self.widgetsView;
                }
            }
        });
    }
}

- (void)saveMapStateIfNeeded
{
    OAMapRendererView* renderView = (OAMapRendererView*)_mapViewController.view;
    
    if ([_mapViewController parentViewController] == self) {
        
        _mapNeedsRestore = YES;
        _mainMapMode = _app.mapMode;
        _mainMapTarget31 = renderView.target31;
        _mainMapZoom = renderView.zoom;
        _mainMapAzimuth = renderView.azimuth;
        _mainMapEvelationAngle = renderView.elevationAngle;
    }
}

- (void)prepareMapForReuse:(Point31)destinationPoint zoom:(CGFloat)zoom newAzimuth:(float)newAzimuth newElevationAngle:(float)newElevationAngle animated:(BOOL)animated
{
    [self saveMapStateIfNeeded];
    
    OAMapRendererView* renderView = (OAMapRendererView*)_mapViewController.view;

    if (isnan(zoom))
        zoom = renderView.zoom;
    if (zoom > 22.0f)
        zoom = 22.0f;
    
    [_mapViewController goToPosition:destinationPoint
                             andZoom:zoom
                            animated:animated];
    
    renderView.azimuth = newAzimuth;
    renderView.elevationAngle = newElevationAngle;
}

- (void)prepareMapForReuse:(UIView *)destinationView mapBounds:(OAGpxBounds)mapBounds newAzimuth:(float)newAzimuth newElevationAngle:(float)newElevationAngle animated:(BOOL)animated
{
    [self saveMapStateIfNeeded];
    
    OAMapRendererView* renderView = (OAMapRendererView*)_mapViewController.view;
    
    if (mapBounds.topLeft.latitude != DBL_MAX) {
        
        const OsmAnd::LatLon latLon(mapBounds.center.latitude, mapBounds.center.longitude);
        Point31 center = [OANativeUtilities convertFromPointI:OsmAnd::Utilities::convertLatLonTo31(latLon)];
        
        float metersPerPixel = [_mapViewController calculateMapRuler];
        
        double distanceH = OsmAnd::Utilities::distance(mapBounds.topLeft.longitude, mapBounds.topLeft.latitude, mapBounds.bottomRight.longitude, mapBounds.topLeft.latitude);
        double distanceV = OsmAnd::Utilities::distance(mapBounds.topLeft.longitude, mapBounds.topLeft.latitude, mapBounds.topLeft.longitude, mapBounds.bottomRight.latitude);
        
        CGSize mapSize;
        if (destinationView)
            mapSize = destinationView.bounds.size;
        else
            mapSize = self.view.bounds.size;
        
        CGFloat newZoomH = distanceH / (mapSize.width * metersPerPixel);
        CGFloat newZoomV = distanceV / (mapSize.height * metersPerPixel);
        CGFloat newZoom = log2(MAX(newZoomH, newZoomV));
        
        CGFloat zoom = renderView.zoom - newZoom;
        if (isnan(zoom))
            zoom = renderView.zoom;
        if (zoom > 22.0f)
            zoom = 22.0f;
        
        [_mapViewController goToPosition:center
                                 andZoom:zoom
                                animated:animated];
    }
    
    
    renderView.azimuth = newAzimuth;
    renderView.elevationAngle = newElevationAngle;
}

- (void)doMapReuse:(UIViewController *)destinationViewController destinationView:(UIView *)destinationView
{
    CGRect newFrame = CGRectMake(0, 0, destinationView.bounds.size.width, destinationView.bounds.size.height);
    if (!CGRectEqualToRect(_mapViewController.view.frame, newFrame))
        _mapViewController.view.frame = newFrame;

    [_mapViewController willMoveToParentViewController:nil];
    
    [destinationViewController addChildViewController:_mapViewController];
    [destinationView addSubview:_mapViewController.view];
    [_mapViewController didMoveToParentViewController:self];
    [destinationView bringSubviewToFront:_mapViewController.view];
    
    _mapViewController.minimap = YES;
}

- (void)modifyMapAfterReuse:(Point31)destinationPoint zoom:(CGFloat)zoom azimuth:(float)azimuth elevationAngle:(float)elevationAngle animated:(BOOL)animated
{
    _mapNeedsRestore = NO;
    OAMapRendererView* renderView = (OAMapRendererView*)_mapViewController.view;
    renderView.azimuth = azimuth;
    renderView.elevationAngle = elevationAngle;
    [_mapViewController goToPosition:destinationPoint andZoom:zoom animated:YES];
    
    _mapViewController.minimap = NO;
}

- (void)modifyMapAfterReuse:(OAGpxBounds)mapBounds azimuth:(float)azimuth elevationAngle:(float)elevationAngle animated:(BOOL)animated
{
    _mapNeedsRestore = NO;
    OAMapRendererView* renderView = (OAMapRendererView*)_mapViewController.view;
    renderView.azimuth = azimuth;
    renderView.elevationAngle = elevationAngle;
    
    if (mapBounds.topLeft.latitude != DBL_MAX) {
        
        const OsmAnd::LatLon latLon(mapBounds.center.latitude, mapBounds.center.longitude);
        Point31 center = [OANativeUtilities convertFromPointI:OsmAnd::Utilities::convertLatLonTo31(latLon)];
        
        float metersPerPixel = [_mapViewController calculateMapRuler];
        
        double distanceH = OsmAnd::Utilities::distance(mapBounds.topLeft.longitude, mapBounds.topLeft.latitude, mapBounds.bottomRight.longitude, mapBounds.topLeft.latitude);
        double distanceV = OsmAnd::Utilities::distance(mapBounds.topLeft.longitude, mapBounds.topLeft.latitude, mapBounds.topLeft.longitude, mapBounds.bottomRight.latitude);
        
        CGSize mapSize = self.view.bounds.size;
        
        CGFloat newZoomH = distanceH / (mapSize.width * metersPerPixel);
        CGFloat newZoomV = distanceV / (mapSize.height * metersPerPixel);
        CGFloat newZoom = log2(MAX(newZoomH, newZoomV));
        
        CGFloat zoom = renderView.zoom - newZoom;
        if (isnan(zoom))
            zoom = renderView.zoom;
        if (zoom > 22.0f)
            zoom = 22.0f;
        
        [_mapViewController goToPosition:center
                                 andZoom:zoom
                                animated:animated];
    }
    
    _mapViewController.minimap = NO;
}

- (void)restoreMapAfterReuse
{
    _app.mapMode = _mainMapMode;
    
    OAMapRendererView* mapView = (OAMapRendererView*)_mapViewController.view;
    mapView.target31 = _mainMapTarget31;
    mapView.zoom = _mainMapZoom;
    mapView.azimuth = _mainMapAzimuth;
    mapView.elevationAngle = _mainMapEvelationAngle;
    
    _mapViewController.minimap = NO;

}

- (void)doMapRestore
{
    [_mapViewController hideTempGpxTrack];
    
    _mapViewController.view.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height);
    
    [_mapViewController willMoveToParentViewController:nil];
    
    [self addChildViewController:_mapViewController];
    [self.view addSubview:_mapViewController.view];
    [_mapViewController didMoveToParentViewController:self];
    [self.view sendSubviewToBack:_mapViewController.view];
    
}

-(void)closeMapSettings
{
    if (_mapSettings)
    {
        [self updateOverlayUnderlayView:[_browseMapViewController isOverlayUnderlayViewVisible]];
        
        OAMapSettingsViewController* lastMapSettingsCtrl = [self.childViewControllers lastObject];
        if (lastMapSettingsCtrl)
            [lastMapSettingsCtrl hidePopup:YES];
        
        _mapSettings = nil;
        
        [self destroyShadowButton];
    }
}

-(CGRect)shadowButtonRect
{
    return self.view.frame;
}

- (void)removeGestureRecognizers
{
    while (self.view.gestureRecognizers.count > 0)
        [self.view removeGestureRecognizer:self.view.gestureRecognizers[0]];
}

- (void)mapSettingsButtonClick:(id)sender
{
    [self removeGestureRecognizers];
    
    _mapSettings = [[OAMapSettingsViewController alloc] initPopup];
    [_mapSettings showPopupAnimated:self parentViewController:nil];
    
    [self createShadowButton:@selector(closeMapSettings) withLongPressEvent:nil topView:_mapSettings.view];
}

- (void)searchButtonClick:(id)sender
{
    [self removeGestureRecognizers];

    OAMapRendererView* mapView = (OAMapRendererView*)_mapViewController.view;
    BOOL isMyLocationVisible = [_mapViewController isMyLocationVisible];

    BOOL searchNearMapCenter = NO;
    OsmAnd::PointI myLocation;
    
    if (!isMyLocationVisible)
    {
        searchNearMapCenter = YES;
        myLocation = mapView.target31;
    }
    else
    {
        CLLocation* newLocation = [OsmAndApp instance].locationServices.lastKnownLocation;
        myLocation = OsmAnd::Utilities::convertLatLonTo31(OsmAnd::LatLon(newLocation.coordinate.latitude, newLocation.coordinate.longitude));
    }

    if (!_searchPOI)
        _searchPOI = [[OAPOISearchViewController alloc] init];
    _searchPOI.myLocation = myLocation;
    _searchPOI.searchNearMapCenter = searchNearMapCenter;
    [self.navigationController presentViewController:_searchPOI animated:YES completion:nil];
}

-(void)onNoSymbolFound:(NSNotification *)notification
{
    //[self hideTargetPointMenu];
}

-(void)onContextMarkerClicked:(NSNotification *)notification
{
    if (!self.targetMenuView.superview)
    {
        [self showTargetPointMenu];
    }
}

-(void)onTargetPointSet:(NSNotification *)notification
{
    NSDictionary *params = [notification userInfo];
    OAPOIType *poiType = [params objectForKey:@"poiType"];
    NSString *objectType = [params objectForKey:@"objectType"];
    NSString *caption = [params objectForKey:@"caption"];
    NSString *buildingNumber = [params objectForKey:@"buildingNumber"];
    UIImage *icon = [params objectForKey:@"icon"];
    double lat = [[params objectForKey:@"lat"] floatValue];
    double lon = [[params objectForKey:@"lon"] floatValue];
    
    NSString *phone = [params objectForKey:@"phone"];
    NSString *openingHours = [params objectForKey:@"openingHours"];
    NSString *url = [params objectForKey:@"url"];
    NSString *desc = [params objectForKey:@"desc"];
    
    CGPoint touchPoint = CGPointMake([[params objectForKey:@"touchPoint.x"] floatValue], [[params objectForKey:@"touchPoint.y"] floatValue]);
    
    OATargetPoint *targetPoint = [[OATargetPoint alloc] init];

    NSString* addressString;
    _targetMenuView.isAddressFound = NO;
    
    if (objectType && [objectType isEqualToString:@"favorite"])
    {
        for (const auto& favLoc : _app.favoritesCollection->getFavoriteLocations()) {
            
            int favLon = (int)(OsmAnd::Utilities::get31LongitudeX(favLoc->getPosition31().x) * 10000.0);
            int favLat = (int)(OsmAnd::Utilities::get31LatitudeY(favLoc->getPosition31().y) * 10000.0);

            if ((int)(lat * 10000.0) == favLat && (int)(lon * 10000.0) == favLon)
            {
                UIColor* color = [UIColor colorWithRed:favLoc->getColor().r/255.0 green:favLoc->getColor().g/255.0 blue:favLoc->getColor().b/255.0 alpha:1.0];
                OAFavoriteColor *favCol = [OADefaultFavorite nearestFavColor:color];
                
                caption = favLoc->getTitle().toNSString();
                icon = [UIImage imageNamed:favCol.iconName];

                targetPoint.type = OATargetFavorite;
                break;
            }
        }

    }
    else if (objectType && [objectType isEqualToString:@"destination"])
    {
        for (OADestination *destination in _app.data.destinations)
        {
            if (destination.latitude == lat && destination.longitude == lon)
            {
                caption = destination.desc;
                icon = [UIImage imageNamed:destination.markerResourceName];

                if (destination.parking)
                    targetPoint.type = OATargetParking;
                else
                    targetPoint.type = OATargetDestination;
                
                break;
            }
        }
    }
    
    if (targetPoint.type == OATargetLocation && poiType)
        targetPoint.type = OATargetPOI;
    
    if (caption.length == 0 && targetPoint.type == OATargetLocation)
    {
        std::shared_ptr<OsmAnd::CachingRoadLocator> _roadLocator;
        _roadLocator.reset(new OsmAnd::CachingRoadLocator(_app.resourcesManager->obfsCollection));
        
        std::shared_ptr<const OsmAnd::Road> road;
        
        const OsmAnd::PointI position31(
                                        OsmAnd::Utilities::get31TileNumberX(lon),
                                        OsmAnd::Utilities::get31TileNumberY(lat));
        
        road = _roadLocator->findNearestRoad(position31,
                                             kMaxRoadDistanceInMeters,
                                             OsmAnd::RoutingDataLevel::Detailed,
                                             true);
        
        NSString* localizedTitle;
        NSString* nativeTitle;
        if (road)
        {
            NSString *prefLang = [[OAAppSettings sharedManager] settingPrefMapLanguage];

            //for (const auto& entry : OsmAnd::rangeOf(road->captions))
            //    NSLog(@"%d=%@", entry.key(), entry.value().toNSString());

            if (prefLang)
            {
                const auto mainLanguage = QString::fromNSString(prefLang);
                const auto localizedName = road->getCaptionInLanguage(mainLanguage);
                if (!localizedName.isNull())
                    localizedTitle = localizedName.toNSString();
            }
            const auto nativeName = road->getCaptionInNativeLanguage();
            if (!nativeName.isNull())
                nativeTitle = nativeName.toNSString();
        }
        
        if (!nativeTitle || [nativeTitle isEqualToString:@""])
        {
            if (buildingNumber.length > 0)
            {
                addressString = buildingNumber;
                _targetMenuView.isAddressFound = YES;
            }
            else
            {
                addressString = OALocalizedString(@"map_no_address");
            }
        }
        else
        {
            if (buildingNumber.length > 0)
                addressString = [NSString stringWithFormat:@"%@, %@", nativeTitle, buildingNumber];
            else
                addressString = nativeTitle;
            _targetMenuView.isAddressFound = YES;
        }
    }
    else if (caption.length > 0)
    {
        _targetMenuView.isAddressFound = YES;
        addressString = caption;
    }
    
    if (_targetMenuView.isAddressFound || addressString)
    {
        _formattedTargetName = addressString;
    }
    else if (poiType)
    {
        _targetMenuView.isAddressFound = YES;
        _formattedTargetName = poiType.nameLocalized;
    }
    else if (buildingNumber.length > 0)
    {
        _targetMenuView.isAddressFound = YES;
        _formattedTargetName = buildingNumber;
    }
    else
    {
        _formattedTargetName = [[[OsmAndApp instance] locationFormatterDigits] stringFromCoordinate:CLLocationCoordinate2DMake(lat, lon)];
    }
    
    _targetLatitude = lat;
    _targetLongitude = lon;
    
    OAMapRendererView* renderView = (OAMapRendererView*)_mapViewController.view;
    
    targetPoint.location = CLLocationCoordinate2DMake(lat, lon);
    targetPoint.title = _formattedTargetName;
    targetPoint.zoom = renderView.zoom;
    targetPoint.touchPoint = touchPoint;
    targetPoint.icon = icon;
    targetPoint.phone = phone;
    targetPoint.openingHours = openingHours;
    targetPoint.url = url;
    targetPoint.desc = desc;
    
    [_targetMenuView setTargetPoint:targetPoint];
    
    [self showTargetPointMenu];
}

-(void)createShadowButton:(SEL)action withLongPressEvent:(SEL)withLongPressEvent topView:(UIView *)topView
{
    if (_shadowButton && [self.view.subviews containsObject:_shadowButton])
        [self destroyShadowButton];
    
    self.shadowButton = [[UIButton alloc] initWithFrame:[self shadowButtonRect]];
    [_shadowButton setBackgroundColor:[UIColor colorWithWhite:0.3 alpha:0]];
    [_shadowButton addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    if (withLongPressEvent) {
        _shadowLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:withLongPressEvent];
        [_shadowButton addGestureRecognizer:_shadowLongPress];
    }
    
    [self.view insertSubview:self.shadowButton belowSubview:topView];
}

-(void)destroyShadowButton
{
    [_shadowButton removeFromSuperview];
    if (_shadowLongPress) {
        [_shadowButton removeGestureRecognizer:_shadowLongPress];
        _shadowLongPress = nil;
    }
    self.shadowButton = nil;
}

- (void)shadowTargetPointLongPress:(UILongPressGestureRecognizer*)gesture
{
    if ( gesture.state == UIGestureRecognizerStateEnded )
        [_mapViewController simulateContextMenuPress:gesture];
}

#pragma mark - OATargetPointViewDelegate

-(void)targetPointAddFavorite
{
    [self hideTargetPointMenu];
}

-(void)targetPointShare
{
}

-(void)targetPointDirection
{
    OADestination *destination = [[OADestination alloc] initWithDesc:_formattedTargetName latitude:_targetLatitude longitude:_targetLongitude];
    if (![_hudViewController.view.subviews containsObject:_destinationViewController.view])
        [_hudViewController.view addSubview:_destinationViewController.view];
    UIColor *color = [_destinationViewController addDestination:destination];
    
    if (color)
    {
        [_mapViewController addDestinationPin:destination.markerResourceName color:destination.color latitude:_targetLatitude longitude:_targetLongitude];
        [_mapViewController hideContextPinMarker];
    }
    else
    {
        [[[UIAlertView alloc] initWithTitle:OALocalizedString(@"cannot_add_destination") message:OALocalizedString(@"cannot_add_marker_desc") delegate:nil cancelButtonTitle:OALocalizedString(@"shared_string_ok") otherButtonTitles:nil
          ] show];
    }
    
    [self hideTargetPointMenu];
}

- (void)targetPointParking
{
    if (![_destinationViewController isPlaceForParking])
    {
        [[[UIAlertView alloc] initWithTitle:OALocalizedString(@"cannot_add_marker") message:OALocalizedString(@"cannot_add_marker_desc") delegate:nil cancelButtonTitle:OALocalizedString(@"shared_string_ok") otherButtonTitles:nil
          ] show];
    }
    else
    {
        OASetParkingViewController *parking = [[OASetParkingViewController alloc] initWithCoordinate:CLLocationCoordinate2DMake(_targetLatitude, _targetLongitude)];
        parking.delegate = self;
        [self.navigationController pushViewController:parking animated:YES];
    }
    
    [self hideTargetPointMenu];
}

- (void)targetPointAddWaypoint
{
    // todo
}

-(void)targetHide
{
    [_mapViewController hideContextPinMarker];
    [self hideTargetPointMenu];
}

-(void)targetHideMenu
{
    [self hideTargetPointMenu];
}

-(void)targetGoToPoint
{
    OsmAnd::LatLon latLon(_targetLatitude, _targetLongitude);
    Point31 point = [OANativeUtilities convertFromPointI:OsmAnd::Utilities::convertLatLonTo31(latLon)];
    [_mapViewController goToPosition:point animated:YES];
}

-(void)showTargetPointMenu
{
    [self.targetMenuView setNavigationController:self.navigationController];
    [self.targetMenuView setMapViewInstance:_mapViewController.view];
    
    [self.targetMenuView doInit];
    [self.targetMenuView doUpdateUI];
    [self.targetMenuView doLayoutSubviews];
    CGRect frame = self.targetMenuView.frame;
    frame.origin.y = DeviceScreenHeight + 10.0;
    self.targetMenuView.frame = frame;
    
    [self.targetMenuView.layer removeAllAnimations];
    if ([self.view.subviews containsObject:self.targetMenuView])
        [self.targetMenuView removeFromSuperview];
    
    [self.view addSubview:self.targetMenuView];
    
    [UIView animateWithDuration:0.3 animations:^{
        
        CGRect frame = self.targetMenuView.frame;
        frame.origin.y = DeviceScreenHeight - self.targetMenuView.bounds.size.height;
        self.targetMenuView.frame = frame;
        
    } completion:^(BOOL finished) {
        
        [self createShadowButton:@selector(hideTargetPointMenu) withLongPressEvent:@selector(shadowTargetPointLongPress:) topView:self.targetMenuView];
        
    }];
}

-(void)hideTargetPointMenu
{
    [self destroyShadowButton];
    
    if (self.targetMenuView.superview)
    {
        CGRect frame = self.targetMenuView.frame;
        frame.origin.y = DeviceScreenHeight + 10.0;
        
        [UIView animateWithDuration:0.4 animations:^{
            self.targetMenuView.frame = frame;
            
        } completion:^(BOOL finished) {
            if (finished)
                [self.targetMenuView removeFromSuperview];
        }];
    }
}

-(void)addParkingReminderToCalendar:(OADestination *)destination
{
    EKEventStore *eventStore = [[EKEventStore alloc] init];
    [eventStore requestAccessToEntityType:EKEntityTypeEvent completion:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error)
            {
                [[[UIAlertView alloc] initWithTitle:OALocalizedString(@"cannot_access_calendar") message:error.localizedDescription delegate:nil cancelButtonTitle:OALocalizedString(@"shared_string_ok") otherButtonTitles:nil] show];
            }
            else if (!granted)
            {
                [[[UIAlertView alloc] initWithTitle:OALocalizedString(@"cannot_access_calendar") message:OALocalizedString(@"reminder_not_set_text") delegate:nil cancelButtonTitle:OALocalizedString(@"shared_string_ok") otherButtonTitles:nil] show];
            }
            else
            {
                EKEvent *event = [EKEvent eventWithEventStore:eventStore];
                event.title = OALocalizedString(@"pickup_car");
                
                event.startDate = destination.carPickupDate;
                event.endDate = destination.carPickupDate;
                
                [event addAlarm:[EKAlarm alarmWithRelativeOffset:-60.0 * 5.0]];
                
                [event setCalendar:[eventStore defaultCalendarForNewEvents]];
                NSError *err;
                [eventStore saveEvent:event span:EKSpanThisEvent error:&err];
                if (err)
                    [[[UIAlertView alloc] initWithTitle:nil message:error.localizedDescription delegate:nil cancelButtonTitle:OALocalizedString(@"shared_string_ok") otherButtonTitles:nil] show];
                else
                    destination.eventIdentifier = [event.eventIdentifier copy];
            }
        });
    }];
}

#pragma mark - OASetParkingDelegate

-(void)addParkingPoint:(OASetParkingViewController *)sender
{
    OADestination *destination = [[OADestination alloc] initWithDesc:_formattedTargetName latitude:sender.coord.latitude longitude:sender.coord.longitude];
    
    destination.parking = YES;
    destination.carPickupDateEnabled = sender.timeLimitActive;
    if (sender.timeLimitActive)
        destination.carPickupDate = sender.date;
    else
        destination.carPickupDate = nil;
    
    if (![_hudViewController.view.subviews containsObject:_destinationViewController.view])
        [_hudViewController.view addSubview:_destinationViewController.view];
    
    UIColor *color = [_destinationViewController addDestination:destination];
    if (color)
    {
        [_mapViewController addDestinationPin:destination.markerResourceName color:destination.color latitude:_targetLatitude longitude:_targetLongitude];
        if (sender.timeLimitActive && sender.addToCalActive)
            [self addParkingReminderToCalendar:destination];
        [_mapViewController hideContextPinMarker];
    }
    else
    {
        [[[UIAlertView alloc] initWithTitle:OALocalizedString(@"cannot_add_marker") message:OALocalizedString(@"cannot_add_marker_desc") delegate:nil cancelButtonTitle:OALocalizedString(@"shared_string_ok") otherButtonTitles:nil
         ] show];
    }
}

#pragma mark - OADestinationViewControllerProtocol

- (void)destinationRemoved:(OADestination *)destination
{
    [_mapViewController removeDestinationPin:destination.color];
}

-(void)destinationViewLayoutDidChange:(BOOL)animated
{
    if ([_hudViewController isKindOfClass:[OABrowseMapAppModeHudViewController class]]) {
        OABrowseMapAppModeHudViewController *browserMap = (OABrowseMapAppModeHudViewController *)_hudViewController;
        [browserMap updateDestinationViewLayout:animated];
        
    } else if ([_hudViewController isKindOfClass:[OADriveAppModeHudViewController class]]) {
        OADriveAppModeHudViewController *drive = (OADriveAppModeHudViewController *)_hudViewController;
        [drive updateDestinationViewLayout:animated];
        
    }
}

- (void)destinationViewMoveToLatitude:(double)lat lon:(double)lon
{
    OsmAnd::LatLon latLon(lat, lon);
    Point31 point = [OANativeUtilities convertFromPointI:OsmAnd::Utilities::convertLatLonTo31(latLon)];
    [_mapViewController goToPosition:point animated:YES];
}

@end
