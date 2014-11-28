//
//  OAPointTableViewCell.h
//  OsmAnd
//
//  Created by Anton Rogachevskiy on 08.11.14.
//  Copyright (c) 2014 OsmAnd. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface OAPointTableViewCell : UITableViewCell

@property (weak, nonatomic) IBOutlet UIView *colorView;
@property (weak, nonatomic) IBOutlet UILabel *titleView;
@property (weak, nonatomic) IBOutlet UIImageView *directionImageView;
@property (weak, nonatomic) IBOutlet UILabel *distanceView;
@property (weak, nonatomic) IBOutlet UIView *cellView;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *cellViewContant;


@end