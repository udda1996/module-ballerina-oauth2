// Copyright (c) 2019, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/auth;
import ballerina/cache;
import ballerina/http;
import ballerina/log;
import ballerina/mime;
import ballerina/stringutils;
import ballerina/time;

# Represents the inbound OAuth2 provider, which calls the introspection server, validates the received credentials,
# and performs authentication and authorization. The `oauth2:InboundOAuth2Provider` is an implementation of the
# `auth:InboundAuthProvider` interface.
# ```ballerina
# oauth2:IntrospectionServerConfig introspectionServerConfig = {
#     url: "https://localhost:9196/oauth2/token/introspect"
# };
# oauth2:InboundOAuth2Provider inboundOAuth2Provider = new(introspectionServerConfig);
# ```
#
public type InboundOAuth2Provider object {

    *auth:InboundAuthProvider;

    IntrospectionServerConfig introspectionServerConfig;

    # Provides authentication based on the provided introspection configurations.
    #
    # + introspectionServerConfig - OAuth2 introspection server configurations
    public function __init(IntrospectionServerConfig introspectionServerConfig) {
        self.introspectionServerConfig = introspectionServerConfig;
    }

# Authenticates the provider OAuth2 tokens with an introspection endpoint.
# ```ballerina
# boolean|auth:Error result = inboundOAuth2Provider.authenticate("<credential>");
# ```
#
# + credential - OAuth2 token to be authenticated
# + return - `true` if authentication is successful, `false` otherwise, or else an `auth:Error` if an error occurred
    public function authenticate(string credential) returns @tainted (boolean|auth:Error) {
        if (credential == "") {
            return false;
        }

        IntrospectionResponse|Error validationResult = validateOAuth2Token(credential, self.introspectionServerConfig);
        if (validationResult is IntrospectionResponse) {
            auth:setAuthenticationContext("oauth2", credential);
            auth:setPrincipal(validationResult?.username, validationResult?.username,
                              getScopes(validationResult?.scopes));
            return true;
        } else {
            return prepareAuthError("OAuth2 validation failed.", validationResult);
        }
    }
};

# Validates the given OAuth2 token.
#```ballerina
# oauth2:IntrospectionResponse|oauth2:Error result = oauth2:validateOAuth2Token(token, introspectionServerConfig);
# ```
#
# + token - OAuth2 token that needs to be validated
# + config -  OAuth2 introspection server configurations
# + return - OAuth2 introspection server response or else a `oauth2:Error` if token validation fails
public function validateOAuth2Token(string token, IntrospectionServerConfig config)
                                    returns @tainted (IntrospectionResponse|Error) {
    cache:Cache? oauth2Cache = config?.oauth2Cache;
    if (oauth2Cache is cache:Cache && oauth2Cache.hasKey(token)) {
        IntrospectionResponse? response = validateFromCache(oauth2Cache, token);
        if (response is IntrospectionResponse) {
            return response;
        }
    }

    // Build the request to be send to the introspection endpoint.
    // Refer: https://tools.ietf.org/html/rfc7662#section-2.1
    http:Request req = new;
    string textPayload = "token=" + token;
    string? tokenTypeHint = config?.tokenTypeHint;
    if (tokenTypeHint is string) {
        textPayload += "&token_type_hint=" + tokenTypeHint;
    }
    req.setTextPayload(textPayload, mime:APPLICATION_FORM_URLENCODED);
    http:Client introspectionClient = new(config.url, config.clientConfig);
    http:Response|http:ClientError response = introspectionClient->post("", req);
    if (response is http:Response) {
        json|error result = response.getJsonPayload();
        if (result is error) {
            return <@untainted> prepareError(result.reason(), result);
        }

        json payload = <json>result;
        boolean active = <boolean>payload.active;
        IntrospectionResponse introspectionResponse = {
            active: active
        };
        if (active) {
            if (payload.username is string) {
                string username = <@untainted> <string>payload.username;
                introspectionResponse.username = username;
            }
            if (payload.scope is string) {
                string scopes = <@untainted> <string>payload.scope;
                introspectionResponse.scopes = scopes;
            }
            if (payload.exp is int) {
                int exp = <@untainted> <int>payload.exp;
                introspectionResponse.exp = exp;
            } else {
                int exp = config.defaultTokenExpTimeInSeconds + (time:currentTime().time / 1000);
                introspectionResponse.exp = exp;
            }

            if (oauth2Cache is cache:Cache) {
                addToCache(oauth2Cache, token, introspectionResponse);
            }
        }
        return introspectionResponse;
    } else {
        return prepareError("Failed to call the introspection endpoint.", response);
    }
}

function addToCache(cache:Cache oauth2Cache, string token, IntrospectionResponse response) {
    cache:Error? result = oauth2Cache.put(token, response);
    if (result is cache:Error) {
        log:printDebug(function() returns string {
            return "Failed to add OAuth2 token to the cache. Introspection response: " + response.toString();
        });
        return;
    }
    log:printDebug(function() returns string {
        return "OAuth2 token added to the cache. Introspection response: " + response.toString();
    });
}

function validateFromCache(cache:Cache oauth2Cache, string token) returns IntrospectionResponse? {
    IntrospectionResponse response = <IntrospectionResponse>oauth2Cache.get(token);
    int? expTime = response?.exp;
    // convert to current time and check the expiry time
    if (expTime is () || expTime > (time:currentTime().time / 1000)) {
        log:printDebug(function() returns string {
            return "OAuth2 token validated from the cache. Introspection response: " + response.toString();
        });
        return response;
    } else {
        cache:Error? result = oauth2Cache.invalidate(token);
        if (result is cache:Error) {
            log:printDebug(function() returns string {
                return "Failed to invalidate OAuth2 token from the cache. Introspection response: " + response.toString();
            });
        }
    }
}

# Reads the scope(s) for the user with the given username.
#
# + scopes - Set of scopes seperated with a space
# + return - Array of groups for the user denoted by the username
function getScopes(string? scopes) returns string[] {
    if (scopes is ()) {
        return [];
    } else {
        string scopeVal = scopes.trim();
        if (scopeVal == "") {
            return [];
        }
        return stringutils:split(scopeVal, " ");
    }
}

# Represents introspection server onfigurations.
#
# + url - URL of the introspection server
# + tokenTypeHint - A hint about the type of the token submitted for introspection
# + oauth2Cache - Cache used to store the OAuth2 token and other related information
# + defaultTokenExpTimeInSeconds - Expiration time of the tokens if introspection response does not contain an `exp` field
# + clientConfig - HTTP client configurations which calls the introspection server
public type IntrospectionServerConfig record {|
    string url;
    string tokenTypeHint?;
    cache:Cache oauth2Cache?;
    int defaultTokenExpTimeInSeconds = 3600;
    http:ClientConfiguration clientConfig = {};
|};

// TODO: Remove API since, no longer used this.
# Represents cached OAuth2 information.
#
# + username - Username of the OAuth2 validated user
# + scopes - Scopes of the OAuth2 validated user
public type InboundOAuth2CacheEntry record {|
    string username;
    string scopes;
|};

# Represents introspection server response.
#
# + active - Boolean indicator of whether or not the presented token is currently active
# + username - Scopes of the OAuth2 validated user
# + scopes - A JSON string containing a space-separated list of scopes associated with this token
# + exp - Scopes of the OAuth2 validated user
public type IntrospectionResponse record {|
    boolean active;
    string username?;
    string scopes?;
    int exp?;
|};