//
//  CBLListsViewController.m
//  Todo
//
//  Created by Pasin Suriyentrakorn on 1/26/17.
//  Copyright © 2017 Pasin Suriyentrakorn. All rights reserved.
//

#import "CBLListsViewController.h"
#import <CouchbaseLite/CouchbaseLite.h>
#import "AppDelegate.h"
#import "CBLConstants.h"
#import "CBLSession.h"
#import "CBLTasksViewController.h"
#import "CBLUsersViewController.h"
#import "CBLUi.h"

@interface CBLListsViewController () <UISearchResultsUpdating> {
    UISearchController *_searchController;
    
    CBLDatabase *_database;
    NSString *_username;
    
    CBLLiveQuery *_listQuery;
    CBLQuery *_searchQuery;
    NSArray<CBLQueryResult*>* _listRows;
    
    CBLLiveQuery *_incompTasksCountsQuery;
    NSMutableDictionary *_incompTasksCounts;
    BOOL shouldUpdateIncompTasksCount;
}

@end

@implementation CBLListsViewController

#pragma mark - UIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Setup SearchController:
    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.dimsBackgroundDuringPresentation = NO;
    self.tableView.tableHeaderView = _searchController.searchBar;
    
    // Get database and username:
    // Get username:
    AppDelegate *app = (AppDelegate *)[UIApplication sharedApplication].delegate;
    _database = app.database;
    _username = [CBLSession sharedInstance].username;
    
    // Load data:
    [self reload];
}


#pragma mark - Database

- (void)reload {
    if (!_listQuery) {
        // TASK LIST:
        _listQuery = [[CBLQuery select:@[S_ID, S_NAME]
                                  from:[CBLQueryDataSource database:_database]
                                 where:[TYPE equalTo:@"task-list"]
                               orderBy:@[[CBLQueryOrdering expression:NAME]]] toLive];
        
        __weak typeof(self) wSelf = self;
        [_listQuery addChangeListener:^(CBLLiveQueryChange *change) {
            if (!change.rows)
                NSLog(@"Error querying task list: %@", change.error);
            _listRows = [change.rows allObjects];
            [wSelf.tableView reloadData];
        }];
        
        // INCOMPLETE TASKS COUNT:
        _incompTasksCountsQuery = [[CBLQuery select:@[S_TASK_LIST_ID, S_COUNT]
                                               from:[CBLQueryDataSource database:_database]
                                              where:[[TYPE equalTo:@"task"]
                                                        andExpression:[COMPLETE equalTo:@(NO)]]
                                            groupBy:@[TASK_LIST_ID]] toLive];
        
        [_incompTasksCountsQuery addChangeListener:^(CBLLiveQueryChange *change) {
            if (change.rows)
                [wSelf updateIncompleteTasksCounts: change.rows];
            else
                NSLog(@"Error querying incomplete task count: %@", change.error);
        }];
    }
    
    [_listQuery start];
    [_incompTasksCountsQuery start];
}

- (void)updateIncompleteTasksCounts:(CBLQueryResultSet*)rows {
    if (!_incompTasksCounts)
        _incompTasksCounts = [NSMutableDictionary dictionary];
    [_incompTasksCounts removeAllObjects];
    
    for (CBLQueryResult *row in rows) {
        _incompTasksCounts[[row stringAtIndex:0]] = [row objectAtIndex:1];
    }
    [self.tableView reloadData];
}


- (void)createTaskList:(NSString*)name {
    NSString *docId = [NSString stringWithFormat:@"%@.%@", _username, [NSUUID UUID].UUIDString];
    CBLDocument *doc = [[CBLDocument alloc] initWithID: docId];
    [doc setObject:@"task-list" forKey:@"type"];
    [doc setObject:name forKey:@"name"];
    [doc setObject:_username forKey:@"owner"];
    
    NSError *error;
    if (![_database saveDocument:doc error:&error])
        [CBLUi showErrorOn:self message:@"Couldn't save task list" error:error];
}

- (void)updateTaskList:(CBLDocument *)list withName:(NSString *)name {
    [list setObject:name forKey:@"name"];
    NSError *error;
    if (![_database saveDocument:list error:&error])
        [CBLUi showErrorOn:self message:@"Couldn't update task list" error:error];
}

- (void)deleteTaskList:(CBLDocument *)list {
    NSError *error;
    if (![_database deleteDocument:list error:&error])
        [CBLUi showErrorOn:self message:@"Couldn't delete task list" error:error];
}

- (void)searchTaskList: (NSString*)name {
    _searchQuery = [CBLQuery select:@[S_ID, S_NAME]
                               from:[CBLQueryDataSource database:_database]
                              where:[[TYPE equalTo:@"task-list"] andExpression:
                                     [NAME like:[NSString stringWithFormat:@"%%%@%%", name]]]
                            orderBy:@[[CBLQueryOrdering expression: NAME]]];
    
    NSError *error;
    NSEnumerator *rows = [_searchQuery run: &error];
    if (!rows)
        NSLog(@"Error searching task list: %@", error);
    
    _listRows = [rows allObjects];
    [self.tableView reloadData];
}

#pragma mark - Actions

- (IBAction)addAction:(id)sender {
    [CBLUi showTextInputOn:self title:@"New Task List" message:nil textField:^(UITextField *text) {
         text.placeholder = @"List name";
         text.autocapitalizationType = UITextAutocapitalizationTypeWords;
     } onOk:^(NSString * _Nonnull name) {
         [self createTaskList:name];
     }];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_listRows count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TaskListCell"
                                                            forIndexPath:indexPath];
    
    CBLQueryResult *row = _listRows[indexPath.row];
    NSString *docID = [row stringAtIndex:0];
    NSString *name = [row stringAtIndex:1];
    
    cell.textLabel.text = name;
    
    NSInteger count = [_incompTasksCounts[docID] integerValue];
    cell.detailTextLabel.text = count > 0 ? [NSString stringWithFormat:@"%ld", (long)count] : @"";
    return cell;
}

-(NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView
                 editActionsForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *docID = [_listRows[indexPath.row] stringAtIndex:0];
    CBLDocument *doc = [_database documentWithID:docID];
    
    // Delete action:
    UITableViewRowAction *delete =
        [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal
                                           title:@"Delete"
                                         handler:
     ^(UITableViewRowAction *action, NSIndexPath *indexPath) {
         // Dismiss row actions:
         [tableView setEditing:NO animated:YES];
         
         // Delete list document:
         [self deleteTaskList:doc];
    }];
    delete.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
    
    // Update action:
    UITableViewRowAction *update = [UITableViewRowAction rowActionWithStyle:UITableViewRowActionStyleNormal
                                                                      title:@"Edit"
                                                                    handler:
     ^(UITableViewRowAction *action, NSIndexPath *indexPath) {
         // Dismiss row actions:
         [tableView setEditing:NO animated:YES];
         
         // Display update list dialog:
         [CBLUi showTextInputOn:self title:@"Edit List" message:nil textField:^(UITextField *text) {
             text.placeholder = @"List name";
             text.text = [doc stringForKey:@"name"];
         } onOk:^(NSString *name) {
             // Update task list with a new name:
             [self updateTaskList:doc withName:name];
         }];
    }];
    update.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
    
    return @[delete, update];
}

#pragma mark - UISearchController

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *name = searchController.searchBar.text ?: @"";
    if ([name length] > 0) {
        [_listQuery stop];
        [_incompTasksCountsQuery stop];
        [self searchTaskList:name];
    } else
        [self reload];
}

#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    NSString *docID = [_listRows[[self.tableView indexPathForSelectedRow].row] stringAtIndex:0];
    CBLDocument *taskList = [_database documentWithID:docID];
    
    UITabBarController *tabBarController = (UITabBarController*)segue.destinationViewController;
    CBLTasksViewController *tasksController = tabBarController.viewControllers[0];
    tasksController.taskList = taskList;
    
    CBLUsersViewController *usersController = tabBarController.viewControllers[1];
    usersController.taskList = taskList;
    
    shouldUpdateIncompTasksCount = YES;
}

@end