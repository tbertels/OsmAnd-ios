//
//  OAHistoryDB.m
//  OsmAnd
//
//  Created by Alexey Kulish on 05/08/15.
//  Copyright (c) 2015 OsmAnd. All rights reserved.
//

#import "OAHistoryDB.h"
#import <sqlite3.h>
#import "OALog.h"
#import "NSData+CRC32.h"

#define TABLE_NAME @"history"
#define POINT_COL_ID @"id"
#define POINT_COL_HASH @"fhash"
#define POINT_COL_TIME @"ftime"
#define POINT_COL_LAT @"flat"
#define POINT_COL_LON @"flon"
#define POINT_COL_NAME @"fname"
#define POINT_COL_TYPE @"ftype"

@implementation OAHistoryDB
{
    sqlite3 *historyDB;
    NSString *databasePath;
    dispatch_queue_t dbQueue;
    dispatch_queue_t syncQueue;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        dbQueue = dispatch_queue_create("history_dbQueue", DISPATCH_QUEUE_SERIAL);
        syncQueue = dispatch_queue_create("history_syncQueue", DISPATCH_QUEUE_SERIAL);
        
        [self createDb];
    }
    return self;
}

- (void)createDb
{
    NSString *dir = [NSHomeDirectory() stringByAppendingString:@"/Library/History"];
    databasePath = [dir stringByAppendingString:@"/history.db"];
    
    BOOL isDir = YES;
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir])
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    
    dispatch_sync(dbQueue, ^{
        
        NSFileManager *filemgr = [NSFileManager defaultManager];
        const char *dbpath = [databasePath UTF8String];
        
        if ([filemgr fileExistsAtPath: databasePath ] == NO)
        {
            if (sqlite3_open(dbpath, &historyDB) == SQLITE_OK)
            {
                char *errMsg;
                const char *sql_stmt = [[NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (%@ ROWID, %@ integer, %@ integer, %@ double, %@ double, %@ text, %@ integer)", TABLE_NAME, POINT_COL_ID, POINT_COL_HASH, POINT_COL_TIME, POINT_COL_LAT, POINT_COL_LON, POINT_COL_NAME, POINT_COL_TYPE] UTF8String];
                
                if (sqlite3_exec(historyDB, sql_stmt, NULL, NULL, &errMsg) != SQLITE_OK)
                {
                    OALog(@"Failed to create table: %@", [NSString stringWithCString:errMsg encoding:NSUTF8StringEncoding]);
                }
                if (errMsg != NULL) sqlite3_free(errMsg);
                
                sqlite3_close(historyDB);
            }
            else
            {
                // Failed to open/create database
            }
        }
        else
        {
            // Upgrade if needed
            /*
            if (sqlite3_open(dbpath, &historyDB) == SQLITE_OK)
            {
                char *errMsg;
                
                const char *sql_stmt = [[NSString stringWithFormat:@"ALTER TABLE %@ ADD COLUMN %@ text", TABLE_NAME, POINT_COL_COLOR] UTF8String];
                if (sqlite3_exec(historyDB, sql_stmt, NULL, NULL, &errMsg) != SQLITE_OK)
                {
                    //Failed to add column. Already exists;
                }
                if (errMsg != NULL) sqlite3_free(errMsg);
            }
            else
            {
                // Failed to upate database
            }
             */
        }
        
    });
    
}

- (int64_t)getRowHash:(double)latitude longitude:(double)longitude name:(NSString *)name
{
    return ((int64_t)(latitude * 100000)) * 100 +
           ((int64_t)(longitude * 100000)) +
           (int64_t)[[name dataUsingEncoding:NSUTF8StringEncoding] crc32];
}

- (void)addPoint:(double)latitude longitude:(double)longitude time:(NSTimeInterval)time name:(NSString *)name type:(OAHistoryType)type
{
    dispatch_async(dbQueue, ^{
        sqlite3_stmt    *statement;
        
        const char *dbpath = [databasePath UTF8String];
        
        if (sqlite3_open(dbpath, &historyDB) == SQLITE_OK)
        {
            NSString *query = [NSString stringWithFormat:@"INSERT INTO %@ (%@, %@, %@, %@, %@, %@) VALUES (?, ?, ?, ?, ?, ?)", TABLE_NAME, POINT_COL_HASH, POINT_COL_TIME, POINT_COL_LAT, POINT_COL_LON, POINT_COL_NAME, POINT_COL_TYPE];
            
            const char *update_stmt = [query UTF8String];
            
            sqlite3_prepare_v2(historyDB, update_stmt, -1, &statement, NULL);
            sqlite3_bind_int64(statement, 1, [self getRowHash:latitude longitude:longitude name:name]);
            sqlite3_bind_int64(statement, 2, (int64_t)time);
            sqlite3_bind_double(statement, 3, latitude);
            sqlite3_bind_double(statement, 4, longitude);
            sqlite3_bind_text(statement, 5, [name UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(statement, 6, type);
            
            sqlite3_step(statement);
            sqlite3_finalize(statement);
            
            sqlite3_close(historyDB);
        }
    });
}

- (void)deletePoint:(int64_t)id
{
    dispatch_async(dbQueue, ^{
        sqlite3_stmt    *statement;
        
        const char *dbpath = [databasePath UTF8String];
        
        if (sqlite3_open(dbpath, &historyDB) == SQLITE_OK)
        {
            NSString *query = [NSString stringWithFormat:@"DELETE FROM %@ WHERE id=?", TABLE_NAME];
            
            const char *update_stmt = [query UTF8String];
            
            sqlite3_prepare_v2(historyDB, update_stmt, -1, &statement, NULL);
            sqlite3_bind_int64(statement, 1, id);
            sqlite3_step(statement);
            sqlite3_finalize(statement);
            
            sqlite3_close(historyDB);
        }
    });
}

- (NSArray *)getPoints:(NSString *)selectPostfix limit:(int)limit
{
    NSMutableArray *arr = [NSMutableArray array];
    
    dispatch_sync(dbQueue, ^{
        
        const char *dbpath = [databasePath UTF8String];
        sqlite3_stmt *statement;
        
        if (sqlite3_open(dbpath, &historyDB) == SQLITE_OK)
        {
            NSMutableString *querySQL = [NSMutableString stringWithString:[NSString stringWithFormat:@"SELECT %@, %@, %@, %@, %@, %@, %@ FROM %@", POINT_COL_ID, POINT_COL_HASH, POINT_COL_TIME, POINT_COL_LAT, POINT_COL_LON, POINT_COL_NAME, POINT_COL_TYPE, TABLE_NAME]];
            
            if (selectPostfix)
                [querySQL appendFormat:@" %@", selectPostfix];

            [querySQL appendFormat:@" ORDER BY %@ DESC", POINT_COL_TIME];
            
            if (limit > 0)
                [querySQL appendFormat:@" LIMIT %d", limit];
            
            const char *query_stmt = [querySQL UTF8String];
            if (sqlite3_prepare_v2(historyDB, query_stmt, -1, &statement, NULL) == SQLITE_OK)
            {
                while (sqlite3_step(statement) == SQLITE_ROW)
                {
                    OAHistoryItem *item = [[OAHistoryItem alloc] init];
                    
                    int64_t hId = sqlite3_column_int64(statement, 0);
                    int64_t hHash = sqlite3_column_int64(statement, 1);
                    int64_t time = sqlite3_column_int64(statement, 2);
                    
                    double lat = sqlite3_column_double(statement, 3);
                    double lon = sqlite3_column_double(statement, 4);
                    
                    NSString *name;
                    if (sqlite3_column_text(statement, 5) != nil)
                        name = [[NSString alloc] initWithUTF8String:(const char *) sqlite3_column_text(statement, 5)];
                    
                    OAHistoryType type = sqlite3_column_int(statement, 6);

                    NSDate *date = [NSDate dateWithTimeIntervalSince1970:time];
                    
                    item.hId = hId;
                    item.hHash = hHash;
                    item.date = date;
                    item.latitude = lat;
                    item.longitude = lon;
                    item.name = name;
                    item.hType = type;
                    
                    [arr addObject:item];
                }
                sqlite3_finalize(statement);
            }
            sqlite3_close(historyDB);
        }
    });
    
    return [NSArray arrayWithArray:arr];
}

- (NSArray *)getSearchHistoryPoints:(int)count
{
    return [self getPoints:[NSString stringWithFormat:@"GROUP BY %@ HAVING MAX(%@)", POINT_COL_HASH, POINT_COL_TIME] limit:count];
}

- (NSArray *)getPointsHavingKnownType:(int)count
{
    return [self getPoints:[NSString stringWithFormat:@"WHERE %@ > %d", POINT_COL_TYPE, OAHistoryTypeUnknown] limit:count];
}

@end