//
//  DanglingPlacehoder.m
//  TestDangling
//
//  Created by luojie on 16/3/26.
//  Copyright © 2016年 vipshop. All rights reserved.
//

#import "YLWildPointerChecker.h"
#import "fishhook.h"
#import <malloc/malloc.h>
#import <pthread.h>
#import <objc/runtime.h>

#define kMaxFreedPointers   10000
#define kMaxFreedSize       1024 * 1024 * 50
#define kPurgeSize          1024 * 1024 * 1

void (*origFree)(void*);    //系统free

typedef struct _DPContext {
    
    CFSetRef classSet;
    Class dpClass;
    size_t dpObjSize;
    
    pthread_mutex_t freeMutex;
    pthread_mutexattr_t mutexAttr;
    CFMutableArrayRef freedPointers;
    size_t freedSize;
    
}DPContext, *DPContextRef;

static CFSetRef setupClassSet() {
    uint count = 0;
    Class* clsList = objc_copyClassList(&count);
    printf("all class count %d\n", count);
    
    CFMutableSetRef set = CFSetCreateMutable(0, count, NULL);
    for (int i=0; i<count; ++i) {
        CFSetAddValue(set, clsList[i]);
    }
    free(clsList);
    
    return set;
}

static DPContextRef DPContextCreate() {
    DPContext* dpc = malloc(sizeof(DPContext));
    if (dpc) {
        memset(dpc, 0, sizeof(DPContext));
        return dpc;
    }
    
    return NULL;
};

static bool DPContextSetup(DPContextRef dpc) {
    if (dpc) {
        dpc->freedPointers = CFArrayCreateMutable(0, kMaxFreedPointers, NULL);
        
        pthread_mutexattr_init(&dpc->mutexAttr);
        pthread_mutexattr_settype(&dpc->mutexAttr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&dpc->freeMutex, &dpc->mutexAttr);
        
        dpc->dpClass = objc_getClass("DanglingPlacehoder");
        dpc->dpObjSize = class_getInstanceSize(dpc->dpClass);
        dpc->classSet = setupClassSet();
        
        return true;
    }
    
    return false;
}

static void  __unused DPContextDestroy(DPContextRef dpc) {
    if (dpc) {
        if (dpc->freedPointers) {
            CFRelease(dpc->freedPointers);
            dpc->freedPointers = NULL;
        }
        
        if (dpc->classSet) {
            CFRelease(dpc->classSet);
            dpc->classSet = NULL;
        }
        
        pthread_mutex_destroy(&dpc->freeMutex);
        pthread_mutexattr_destroy(&dpc->mutexAttr);
    }
    
    free(dpc);
}

static DPContextRef sharedDPContext() {
    static DPContextRef dpc = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        DPContextRef obj = DPContextCreate();
        if (obj && DPContextSetup(obj))
            dpc = obj;
    });
    return dpc;
}

static bool prefix(const char *pre, const char *str)
{
    return strncmp(pre, str, strlen(pre)) == 0;
}

static bool shouldUseFakeFree(const char* className) {
    return !prefix("__", className) && !prefix("_", className) && !prefix("OS", className);
}

static void purge(size_t size, DPContextRef dpc) {
    pthread_mutex_lock(&dpc->freeMutex);
    
    printf("purge %lu\n", size);
    
    size_t toPurgeSize = MIN(dpc->freedSize, size);
    size_t sz = 0;
    
    while (sz < toPurgeSize && CFArrayGetCount(dpc->freedPointers) > 0) {
        void* p = (void*)CFArrayGetValueAtIndex(dpc->freedPointers, 0);
        CFArrayRemoveValueAtIndex(dpc->freedPointers, 0);
        sz += malloc_size(p);
        origFree(p);
    }
    
    pthread_mutex_unlock(&dpc->freeMutex);
}

static void fakeFree(void* p, DPContextRef dpc) {
    pthread_mutex_lock(&dpc->freeMutex);
    
    printf("fake free %p\n", p);
    
    CFArrayAppendValue(dpc->freedPointers, p);
    dpc->freedSize += malloc_size(p);
    
    if (CFArrayGetCount(dpc->freedPointers) > kMaxFreedPointers || dpc->freedSize > kMaxFreedSize) {
        purge(kPurgeSize, dpc);
    }
    
    pthread_mutex_unlock(&dpc->freeMutex);
}

@interface YLWildPointerChecker ()

@property (nonatomic, assign) Class originClass;

@end

static void danglingPlacehoderFree(void* p) {
    
    id obj = (id)(p);
    Class originClass = object_getClass(obj);
    
    DPContextRef dpc = sharedDPContext();
    
    if (originClass && CFSetContainsValue(dpc->classSet, originClass)) {
        const char* name = object_getClassName(obj);
        if (shouldUseFakeFree(name)) {
            Class dpClass = objc_getClass("DanglingPlacehoder");
            size_t msize = malloc_size(p);
            memset(p, 0x55, msize);
            
            printf("%s object %p is freed! size=%lu\n", name, obj, msize);
            if (msize >= dpc->dpObjSize) {
                memcpy(p, &dpClass, sizeof(void*));
                YLWildPointerChecker* dp = (YLWildPointerChecker*)p;
                dp.originClass = originClass;
            }
            
            fakeFree(p, dpc);
            return;
        }
    }
    
    origFree(p);
}

@implementation YLWildPointerChecker

+ (void)initPlaceholder {
    sharedDPContext();
    rebind_symbols((struct rebinding[1]){{"free", danglingPlacehoderFree, (void *)&origFree}}, 1);
}

- (id)forwardingTargetForSelector:(SEL)selector {
    NSAssert(0, [self errorDescriptionForSelector:selector]);
    return nil;
}

- (void)dealloc {
    [super dealloc];
    NSAssert(0, [self errorDescriptionForSelector:@selector(dealloc)]);
}

- (oneway void)release {
    NSAssert(0, [self errorDescriptionForSelector:@selector(release)]);
}

- (instancetype)autorelease {
    NSAssert(0, [self errorDescriptionForSelector:@selector(autorelease)]);
    return nil;
}

- (NSString*)errorDescriptionForSelector:(SEL)selector {
    return [NSString stringWithFormat: @"野指针!!! @%p, [%s %@]", self, class_getName(_originClass), NSStringFromSelector(selector)];
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return YES;
}

@end

@implementation YLWildPointerChecker (load) //类别的load最后执行，所以我们选择在这里初始化

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [self initPlaceholder];
    });
}

@end
