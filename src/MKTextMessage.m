// Copyright 2009-2012 The MumbleKit Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <MumbleKit/MKTextMessage.h>

static NSString *MKSanitizeStringForXMLParsing(NSString *string) {
    if (string == nil || [string length] == 0) {
        return string;
    }
    
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"&(?!#?[A-Za-z0-9]+;)" options:0 error:&error];
    if (regex == nil || error != nil) {
        return string;
    }
    
    return [regex stringByReplacingMatchesInString:string options:0 range:NSMakeRange(0, [string length]) withTemplate:@"&amp;"];
}

@interface MKTextMessage () <NSXMLParserDelegate> {
    NSString         *_rawStr;
    NSMutableString  *_plainStr;
    NSString         *_filteredStr;
    NSMutableArray   *_imagesArray;
    NSMutableArray   *_linksArray;
}
- (id) initWithString:(NSString *)str;
@end

@implementation MKTextMessage

- (id) initWithString:(NSString *)str {
    if ((self = [super init])) {
        _rawStr = [str retain];
        _imagesArray = [[NSMutableArray alloc] init];
        _linksArray = [[NSMutableArray alloc] init];
        NSRange r = [_rawStr rangeOfString:@"<"];
        BOOL possiblyHtml = r.location != NSNotFound;
        if (possiblyHtml) {
            _plainStr = [[NSMutableString alloc] init];
            NSString *xmlSafeString = MKSanitizeStringForXMLParsing(_rawStr);
            NSXMLParser *xmlParser = [[NSXMLParser alloc] initWithData:[[NSString stringWithFormat:@"<doc>%@</doc>", xmlSafeString] dataUsingEncoding:NSUTF8StringEncoding]];
            [xmlParser setDelegate:self];
            [xmlParser parse];
            [xmlParser release];

            _filteredStr = [_plainStr copy];
            [_plainStr release];
            _plainStr = nil;
        }
    }

    return self;
}

- (void) dealloc {
    [_rawStr release];
    [_plainStr release];
    [_filteredStr release];
    [_imagesArray release];
    [_linksArray release];
    [super dealloc];
}

+ (MKTextMessage *) messageWithString:(NSString *)msg {
    return [[[MKTextMessage alloc] initWithString:msg] autorelease];
}

+ (MKTextMessage *) messageWithPlainText:(NSString *)msg {
    return [[[MKTextMessage alloc] initWithString:msg] autorelease];
}

+ (MKTextMessage *) messageWithHTML:(NSString *)msg {
    return [[[MKTextMessage alloc] initWithString:msg] autorelease];
}

- (NSString *) plainTextString {
    if (_filteredStr != nil) {
        return _filteredStr;
    }
    return _rawStr;
}

- (NSString *) HTMLString {
    return _rawStr;
}

- (NSArray *) embeddedLinks {
    return _linksArray;
}

- (NSArray *) embeddedImages {
    return _imagesArray;
}

#pragma mark - NSXMLParserDelegate

- (void) parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"img"]) {
        NSString *src = [attributeDict objectForKey:@"src"];
        if ([src hasPrefix:@"data:"]) {
            [_imagesArray addObject:src];
        }
    } else if ([elementName isEqualToString:@"a"]) {
        NSString *href = [attributeDict objectForKey:@"href"];
        if (href) {
            [_linksArray addObject:href];
        }
    }
}

- (void) parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"br"] || [elementName isEqualToString:@"p"])
        [_plainStr appendString:@"\n"];
}

- (void) parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_plainStr appendString:string];
}

@end
