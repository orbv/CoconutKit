//
//  NSManagedObject+HLSExtensions.m
//  CoconutKit
//
//  Created by Samuel Défago on 21.10.11.
//  Copyright (c) 2011 Hortis. All rights reserved.
//

#import "NSManagedObject+HLSExtensions.h"

#import "HLSAssert.h"
#import "HLSCategoryLinker.h"
#import "HLSError.h"
#import "HLSLogger.h"
#import "HLSModelManager.h"
#import "HLSRuntime.h"
#import "NSDictionary+HLSExtensions.h"
#import "NSObject+HLSExtensions.h"
#import "UITextField+HLSExtensions.h"

#import <objc/runtime.h>

HLSLinkCategory(NSManagedObject_HLSExtensions)

static BOOL s_injectedManagedObjectValidation = NO;

// External linkage
BOOL hlsInjectedManagedObjectValidation(void);

// Original implementation of the methods we swizzle
static void (*s_NSManagedObject_HLSExtensions__initialize_Imp)(id, SEL) = NULL;

static NSString * const kManagedObjectMulitpleValidationError = @"kManagedObjectMulitpleValidationError";

static Method instanceMethodOnClass(Class class, SEL sel);
static SEL checkSelectorForValidationSelector(SEL sel);
static BOOL validateProperty(id self, SEL sel, id *pValue, NSError **pError);
static BOOL validateObjectConsistency(id self, SEL sel, NSError **pError);
static BOOL validateObjectConsistencyInClassHierarchy(id self, Class class, SEL sel, NSError **pError);

static void combineErrors(NSError *newError, NSError **pOriginalError);

@interface NSManagedObject (HLSExtensionsPrivate)

+ (void)swizzledInitialize;

@end

@implementation NSManagedObject (HLSExtensions)

#pragma mark Query helpers

+ (id)insertIntoManagedObjectContext:(NSManagedObjectContext *)managedObjectContext
{
    return [NSEntityDescription insertNewObjectForEntityForName:[self className] inManagedObjectContext:managedObjectContext];
}

+ (id)insert
{
    return [self insertIntoManagedObjectContext:[HLSModelManager defaultModelContext]];
}

+ (NSArray *)filteredObjectsUsingPredicate:(NSPredicate *)predicate
                    sortedUsingDescriptors:(NSArray *)sortDescriptors
                    inManagedObjectContext:(NSManagedObjectContext *)managedObjectContext
{
    NSEntityDescription *entityDescription = [NSEntityDescription entityForName:[self className]
                                                         inManagedObjectContext:managedObjectContext];
    NSFetchRequest *fetchRequest = [[[NSFetchRequest alloc] init] autorelease];
    [fetchRequest setEntity:entityDescription];
    fetchRequest.sortDescriptors = sortDescriptors;
    fetchRequest.predicate = predicate;
    
    NSError *error = nil;
    NSArray *objects = [managedObjectContext executeFetchRequest:fetchRequest error:&error];
    if (error) {
        HLSLoggerError(@"Could not retrieve objects; reason: %@", error);
        return nil;
    }
    
    return objects;
}

+ (NSArray *)filteredObjectsUsingPredicate:(NSPredicate *)predicate
                    sortedUsingDescriptors:(NSArray *)sortDescriptors
{
    return [self filteredObjectsUsingPredicate:predicate
                        sortedUsingDescriptors:sortDescriptors 
                        inManagedObjectContext:[HLSModelManager defaultModelContext]];
}

+ (NSArray *)allObjectsSortedUsingDescriptors:(NSArray *)sortDescriptors
                       inManagedObjectContext:(NSManagedObjectContext *)managedObjectContext
{
    return [self filteredObjectsUsingPredicate:nil 
                        sortedUsingDescriptors:sortDescriptors 
                        inManagedObjectContext:managedObjectContext];
}

+ (NSArray *)allObjectsSortedUsingDescriptors:(NSArray *)sortDescriptors
{
    return [self allObjectsSortedUsingDescriptors:sortDescriptors inManagedObjectContext:[HLSModelManager defaultModelContext]];
}

+ (NSArray *)allObjectsInManagedObjectContext:(NSManagedObjectContext *)managedObjectContext
{
    return [self allObjectsSortedUsingDescriptors:nil 
                           inManagedObjectContext:managedObjectContext];
}

+ (NSArray *)allObjects
{
    return [self allObjectsInManagedObjectContext:[HLSModelManager defaultModelContext]];
}

#pragma mark Validation wrapper injection

+ (void)injectValidation
{
    if (s_injectedManagedObjectValidation) {
        HLSLoggerInfo(@"Managed object validations already injected");
        return;
    }
    
    s_NSManagedObject_HLSExtensions__initialize_Imp = (void (*)(id, SEL))HLSSwizzleClassSelector([NSManagedObject class], @selector(initialize), @selector(swizzledInitialize));
    
    s_injectedManagedObjectValidation = YES;
}

#pragma mark Checking if a value is correct for a specific field

- (BOOL)checkValue:(id)value forKey:(NSString *)key error:(NSError **)pError
{
    // Remark: Do not invoke validation methods directly. Use validateValue:forKey:error: with a key. This guarantees
    //         that any validation logic in the xcdatamodel is also triggered
    //         See http://developer.apple.com/library/mac/#documentation/Cocoa/Conceptual/CoreData/Articles/cdValidation.html
    // (remark: The code below also deals correctly with &nil)
    return [self validateValue:&value forKey:key error:pError];
}

#pragma mark Global validation method stubs

- (BOOL)checkForConsistency:(NSError **)pError
{
    return YES;
}

- (BOOL)checkForDelete:(NSError **)pError
{
    return YES;
}

@end

@implementation NSManagedObject (HLSExtensionsPrivate)

+ (void)load
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    [HLSError registerDefaultCode:NSValidationMultipleErrorsError 
                           domain:@"ch.hortis.CoconutKit" 
             localizedDescription:NSLocalizedString(@"Multiple validation errors", @"Multiple validation errors")
                    forIdentifier:kManagedObjectMulitpleValidationError];
    
    [pool drain];
}

/**
 * Inject validation wrappers into managed object classes automagically.
 *
 * Registering validation wrappers in +load is not an option, because the load method is executed once. Since we need to inject
 * code in each model object class, we must do it in +initialize since this methos will be called for each subclass. We could
 * have implemented +load to run over all classes, finding out which ones are managed object classes, then injecting validation
 * wrappers, but swizzling +initialize is conceptually better: It namely would behave well if classes were also added at runtime
 * (this would not be the case with +load which would already have been executed in such cases)
 *
 * Note that we cannot have an +initialize method in a category (it would prevent any +initialize method defined on the class from 
 * being called, and here there exists such a method on NSManagedObject; it is also extremely important to call it, otherwise the Core
 * Data runtime will be incomplete and silly crashes will occur). We therefore must swizzle the existing +initialize method instead
 * and call the existing implementation first.
 */
+ (void)swizzledInitialize
{
    // Call swizzled implementation
    (*s_NSManagedObject_HLSExtensions__initialize_Imp)([NSManagedObject class], @selector(initialize));
    
    // No class identity test here. This must be executed for all objects in the hierarchy rooted at NSManagedObject, so that we can
    // locate the @dynamic properties we are interested in (those which need validation)
    
    // Inject validation methods for each managed object property
    unsigned int numberOfProperties = 0;
    objc_property_t *properties = class_copyPropertyList(self, &numberOfProperties);
    BOOL added = NO;
    for (unsigned int i = 0; i < numberOfProperties; ++i) {
        objc_property_t property = properties[i];
        
        // Only dynamic properties (i.e. properties generated by Core Data)
        NSArray *attributes = [[NSString stringWithCString:property_getAttributes(property) encoding:NSUTF8StringEncoding] componentsSeparatedByString:@","];
        if (! [attributes containsObject:@"D"]) {
            continue;
        }
        
        NSString *propertyName = [NSString stringWithCString:property_getName(property) encoding:NSUTF8StringEncoding];
        if ([propertyName length] == 0) {
            HLSLoggerError(@"Missing property name");
            continue;
        }
        
        NSString *validationSelectorName = [NSString stringWithFormat:@"validate%@%@:error:", [[propertyName substringToIndex:1] uppercaseString], 
                                            [propertyName substringFromIndex:1]];
        NSString *types = [NSString stringWithFormat:@"%s%s%s%s%s", @encode(BOOL), @encode(id), @encode(SEL), @encode(id *), @encode(id *)];
        if (! class_addMethod(self, 
                              NSSelectorFromString(validationSelectorName),         // Remark: (SEL)[validationSelectorName cStringUsingEncoding:NSUTF8StringEncoding] does NOT work (returns YES, but IMP does not get called)
                              (IMP)validateProperty, 
                              [types cStringUsingEncoding:NSUTF8StringEncoding])) {
            HLSLoggerError(@"Failed to add %@ method dynamically", validationSelectorName);
            continue;
        }
        
        HLSLoggerDebug(@"Automatically added validation wrapper %@ on class %@", validationSelectorName, self);
        
        added = YES;
    }
    free(properties);
    
    // If at least one validation method was injected (i.e. if there are fields to validate), we must also inject a global validation
    if (added) {
        NSString *types = [NSString stringWithFormat:@"%s%s%s%s", @encode(BOOL), @encode(id), @encode(SEL), @encode(id *)];
        if (! class_addMethod(self, 
                              @selector(validateForInsert:), 
                              (IMP)validateObjectConsistency,
                              [types cStringUsingEncoding:NSUTF8StringEncoding])) {
            HLSLoggerError(@"Failed to add validateForInsert: method dynamically");
        }
        if (! class_addMethod(self, 
                              @selector(validateForUpdate:), 
                              (IMP)validateObjectConsistency,
                              [types cStringUsingEncoding:NSUTF8StringEncoding])) {
            HLSLoggerError(@"Failed to add validateForUpdate: method dynamically");
        }        
        if (! class_addMethod(self, 
                              @selector(validateForDelete:), 
                              (IMP)validateObjectConsistency,
                              [types cStringUsingEncoding:NSUTF8StringEncoding])) {
            HLSLoggerError(@"Failed to add validateForDelete: method dynamically");
        }
    }    
}

@end

#pragma mark Injection status

BOOL injectedManagedObjectValidation(void)
{
    return s_injectedManagedObjectValidation;
}

#pragma mark Utility functions

/**
 * Given a class and a selector, returns the underlying method iff it is implemented by this class. Unlike
 * class_getInstanceMethod, this method returns NULL if a parent class implements the method
 */
static Method instanceMethodOnClass(Class class, SEL sel)
{
    unsigned int numberOfMethods = 0;
    Method *methods = class_copyMethodList(class, &numberOfMethods);
    for (unsigned int i = 0; i < numberOfMethods; ++i) {
        Method method = methods[i];
        if (method_getName(method) == sel) {
            return method;
        }
    }
    return NULL;
}

/**
 * Return the check selector associated with a validation selector
 */
static SEL checkSelectorForValidationSelector(SEL sel)
{
    // Special cases of global validation for insert / update: One common method since always identical
    NSString *selectorName = [NSString stringWithCString:(char *)sel encoding:NSUTF8StringEncoding];
    if ([selectorName isEqual:@"validateForInsert:"] || [selectorName isEqual:@"validateForUpdate:"]) {
        return NSSelectorFromString(@"checkForConsistency:");
    }
    // In all other cases, the check method bears the same name as the validation method, but beginning with "check"
    else {
        NSString *checkSelectorName = [selectorName stringByReplacingOccurrencesOfString:@"validate" withString:@"check"];
        return  NSSelectorFromString(checkSelectorName);
    }    
}

#pragma mark Validation

/**
 * Implementation common to all injected single validation methods (validate<FieldName>:error:)
 *
 * This implementation calls the underlying check method and performs Core Data error chaining
 */
static BOOL validateProperty(id self, SEL sel, id *pValue, NSError **pError)
{
    // If the method does not exist, valid
    SEL checkSel = checkSelectorForValidationSelector(sel);
    Method method = class_getInstanceMethod([self class], checkSel);
    if (! method) {
        return YES;
    }
    
    // Get the check method
    id value = pValue ? *pValue : nil;
    BOOL (*checkImp)(id, SEL, id, NSError **) = (BOOL (*)(id, SEL, id, NSError **))method_getImplementation(method);
    
    // Check
    NSError *newError = nil;
    if (! (*checkImp)(self, checkSel, value, &newError)) {
        combineErrors(newError, pError);
        return NO;
    }
    else if (newError) {
        HLSLoggerWarn(@"The %s method returns YES but also an error. The error has been discarded, but the method implementation is incorrect", 
                      (char *)checkSel);
    }
    
    return YES;
}

/**
 * Implementation common to all injected global validation methods:
 *   -[NSManagedObject validateForInsert:]
 *   -[NSManagedObject validateForUpdate:]
 *   -[NSManagedObject validateForDelete:]
 *
 * This implementation calls the underlying check methods, performs Core Data error chaining, and ensures that these methods 
 * get consistently called along the inheritance hierarchy. This is strongly recommended by the Core Data documentation, and
 * in fact failing to do so leads to undefined behavior: The -[NSManagedObject validateForUpdate:] and 
 * -[NSManagedObject validateForInsert:] methods are namely where individual validations are called! If those were not
 * called, individual validations would not be called either!
 */
static BOOL validateObjectConsistency(id self, SEL sel, NSError **pError)
{
    return validateObjectConsistencyInClassHierarchy(self, [self class], sel, pError);
}

/**
 * Validate the consistency of self, applying to it the sel defined for the class given as parameter. This methods can
 * therefore be used to check global object consistency at all levels of the managed object inheritance hierarchy
 */
static BOOL validateObjectConsistencyInClassHierarchy(id self, Class class, SEL sel, NSError **pError)
{
    if (class == [NSManagedObject class]) {
        // Get the validation method. This method exists on NSManagedObject, no need to test if responding to selector
        BOOL (*imp)(id, SEL, NSError **) = (BOOL (*)(id, SEL, NSError **))class_getMethodImplementation(class, sel);
        
        // Validate. This is where individual validations are triggered
        NSError *newError = nil;
        if (! (*imp)(self, sel, &newError)) {
            combineErrors(newError, pError);
            return NO;
        }
        
        return YES;
    }
    else {
        BOOL valid = YES;
        
        // Climb up the inheritance hierarchy
        NSError *newError = nil;
        if (! validateObjectConsistencyInClassHierarchy(self, class_getSuperclass(class), sel, &newError)) {
            combineErrors(newError, pError);
            valid = NO;
        }
        
        // If no check method has been defined at this class hierarchy level, valid (i.e. we do not alter the above
        // validation status)
        SEL checkSel = checkSelectorForValidationSelector(sel);
        Method method = instanceMethodOnClass(class, checkSel);
        if (! method) {
            return valid;
        }
        
        // A check method has been found. Call the underlying check method implementation
        BOOL (*checkImp)(id, SEL, NSError **) = (BOOL (*)(id, SEL, NSError **))method_getImplementation(method);
        newError = nil;
        if (! (*checkImp)(self, checkSel, &newError)) {
            combineErrors(newError, pError);
            valid = NO;
        }
        else if (newError) {
            HLSLoggerWarn(@"The %s method returns YES but also an error. The error has been discarded, but the method implementation is incorrect", 
                          (char *)checkSel);
        }
        
        return valid;
    }
}

#pragma mark Combining Core Data errors correctly

/**
 * Combine a new error with an existing error. This function implements the approach recommended in the Core Data
 * programming guide, see http://developer.apple.com/library/mac/#documentation/Cocoa/Conceptual/CoreData/Articles/cdValidation.html
 */
static void combineErrors(NSError *newError, NSError **pExistingError)
{
    // If no new error, nothing to do
    if (! newError) {
        return;
    }
    
    // If the caller is not interested in errors, nothing to do
    if (! pExistingError) {
        return;
    }
    
    // An existing error is already available. Combine as multiple error
    if (*pExistingError) {
        // Already a multiple error. Add error to the list (this can only be done cleanly by creating a new error)
        NSDictionary *userInfo = nil;
        if ([*pExistingError code] == NSValidationMultipleErrorsError) {
            userInfo = [*pExistingError userInfo];
            NSArray *errors = [userInfo objectForKey:NSDetailedErrorsKey];
            errors = [errors arrayByAddingObject:newError];
            userInfo = [userInfo dictionaryBySettingObject:errors forKey:NSDetailedErrorsKey];            
        }
        // Not a multiple error yet. Combine into a multiple error
        else {
            NSArray *errors = [NSArray arrayWithObjects:*pExistingError, newError, nil];
            userInfo = [NSDictionary dictionaryWithObject:errors forKey:NSDetailedErrorsKey];
        }
        *pExistingError = [HLSError errorFromIdentifier:kManagedObjectMulitpleValidationError
                                               userInfo:userInfo];
    }
    // No error yet, just use the new error
    else {
        *pExistingError = newError;
    }
}
