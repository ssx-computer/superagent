//
//  IAGModelCheck.h
//  iAgent
//
//  「模型到底能不能用」的分步体检，服务于 POST /api/model/check。
//
//  为什么要有它：用户最常见的失败是"baseUrl 少了一层 /v1""key 没有这个模型的权限"
//  "中转端点不理会 stream:true"——这些从一句 HTTP 401 里看不出来。体检把整条链路拆成
//  5 步顺序执行，每一步都留下 detail，前端可以原样展示给用户定位问题。
//

#ifndef IAG_MODEL_CHECK_H
#define IAG_MODEL_CHECK_H

#import <Foundation/Foundation.h>

@class IAGConfig;

@interface IAGModelCheck : NSObject

/// 执行一次体检。`overrides` 里可以带 baseUrl / apiKey / model 覆盖当前配置（都可缺省）。
/// 无论成功失败都返回一个可直接 `[response setJSON:]` 的字典：
///   { ok, verdict, hint, steps[], models[] }
/// 永不抛异常，也永不因为远程失败而不返回。
+ (NSDictionary *)runWithConfig:(IAGConfig *)config overrides:(NSDictionary *)overrides;

@end

#endif /* IAG_MODEL_CHECK_H */
