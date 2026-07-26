import { useTranslation } from "react-i18next";
import { FormLabel } from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import type { CodexSessionHeaderAdapter, Retry429Config } from "@/types";
import {
  parseBodyOverrideJson,
  parseHeaderOverrideJson,
} from "@/lib/requestOverrides";

interface LocalProxyRequestOverridesFieldProps {
  headersJson: string;
  bodyJson: string;
  onHeadersJsonChange: (value: string) => void;
  onBodyJsonChange: (value: string) => void;
  showModelHubControls?: boolean;
  codexSessionHeaderAdapter?: CodexSessionHeaderAdapter;
  retry429?: Retry429Config;
  onCodexSessionHeaderAdapterChange?: (
    value: CodexSessionHeaderAdapter | undefined,
  ) => void;
  onRetry429Change?: (value: Retry429Config | undefined) => void;
}

const DEFAULT_RETRY_429: Retry429Config = {
  maxRetries: 10,
  baseDelayMs: 1000,
  maxDelayMs: 30000,
  honorRetryAfter: true,
};

export function LocalProxyRequestOverridesField({
  headersJson,
  bodyJson,
  onHeadersJsonChange,
  onBodyJsonChange,
  showModelHubControls = false,
  codexSessionHeaderAdapter,
  retry429,
  onCodexSessionHeaderAdapterChange,
  onRetry429Change,
}: LocalProxyRequestOverridesFieldProps) {
  const { t } = useTranslation();
  const headerError = parseHeaderOverrideJson(headersJson).error;
  const bodyError = parseBodyOverrideJson(bodyJson).error;

  return (
    <div className="space-y-3">
      <div className="space-y-1">
        <FormLabel>
          {t("providerForm.localProxyRequestOverrides", {
            defaultValue: "本地代理请求覆盖",
          })}
        </FormLabel>
        <p className="text-xs text-muted-foreground">
          {t("providerForm.localProxyRequestOverridesHint", {
            defaultValue:
              "仅在本地路由/代理接管后生效，应用于协议转换后的上游请求。",
          })}
        </p>
      </div>

      {showModelHubControls && (
        <div className="space-y-3 rounded-md border border-border-default p-3">
          <div className="flex items-start justify-between gap-3">
            <div className="space-y-1">
              <Label htmlFor="modelhub-session-header-adapter">
                {t("providerForm.modelhubSessionHeaderAdapter", {
                  defaultValue: "ModelHub 会话头适配",
                })}
              </Label>
              <p className="text-xs text-muted-foreground">
                {t("providerForm.modelhubSessionHeaderAdapterHint", {
                  defaultValue:
                    "把官方 Codex 的 session-id/thread-id 转换为内部 ModelHub 链路需要的 session_id/thread_id/extra。仅在本地路由接管后生效。",
                })}
              </p>
            </div>
            <Switch
              id="modelhub-session-header-adapter"
              aria-label={t("providerForm.modelhubSessionHeaderAdapter", {
                defaultValue: "ModelHub 会话头适配",
              })}
              checked={codexSessionHeaderAdapter === "modelhub"}
              onCheckedChange={(checked) => {
                onCodexSessionHeaderAdapterChange?.(
                  checked ? "modelhub" : undefined,
                );
                if (!checked) onRetry429Change?.(undefined);
              }}
            />
          </div>

          {codexSessionHeaderAdapter === "modelhub" && (
            <div className="space-y-3 border-t border-border-default pt-3">
              <div className="flex items-start justify-between gap-3">
                <div className="space-y-1">
                  <Label htmlFor="same-provider-retry-429">
                    {t("providerForm.sameProviderRetry429", {
                      defaultValue: "同 Provider 429 重试",
                    })}
                  </Label>
                  <p className="text-xs text-muted-foreground">
                    {t("providerForm.sameProviderRetry429Hint", {
                      defaultValue:
                        "收到 HTTP 429 时保持当前 ModelHub Provider 和会话头不变，按退避策略重试。",
                    })}
                  </p>
                </div>
                <Switch
                  id="same-provider-retry-429"
                  aria-label={t("providerForm.sameProviderRetry429", {
                    defaultValue: "同 Provider 429 重试",
                  })}
                  checked={retry429 !== undefined}
                  onCheckedChange={(checked) =>
                    onRetry429Change?.(
                      checked ? { ...DEFAULT_RETRY_429 } : undefined,
                    )
                  }
                />
              </div>

              {retry429 && (
                <div className="grid gap-3 md:grid-cols-3">
                  <div className="space-y-1">
                    <Label htmlFor="retry-429-max-retries">
                      {t("providerForm.retry429MaxRetries", {
                        defaultValue: "最大重试次数",
                      })}
                    </Label>
                    <Input
                      id="retry-429-max-retries"
                      type="number"
                      min={0}
                      max={10}
                      step={1}
                      value={retry429.maxRetries}
                      onChange={(event) =>
                        onRetry429Change?.({
                          ...retry429,
                          maxRetries: Number(event.target.value),
                        })
                      }
                    />
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor="retry-429-base-delay">
                      {t("providerForm.retry429BaseDelay", {
                        defaultValue: "基础延迟（毫秒）",
                      })}
                    </Label>
                    <Input
                      id="retry-429-base-delay"
                      type="number"
                      min={100}
                      max={60000}
                      step={100}
                      value={retry429.baseDelayMs}
                      onChange={(event) =>
                        onRetry429Change?.({
                          ...retry429,
                          baseDelayMs: Number(event.target.value),
                        })
                      }
                    />
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor="retry-429-max-delay">
                      {t("providerForm.retry429MaxDelay", {
                        defaultValue: "最大延迟（毫秒）",
                      })}
                    </Label>
                    <Input
                      id="retry-429-max-delay"
                      type="number"
                      min={100}
                      max={60000}
                      step={100}
                      value={retry429.maxDelayMs}
                      onChange={(event) =>
                        onRetry429Change?.({
                          ...retry429,
                          maxDelayMs: Number(event.target.value),
                        })
                      }
                    />
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      )}

      <div className="grid gap-3 md:grid-cols-2">
        <div className="space-y-2">
          <FormLabel className="text-xs text-muted-foreground">
            {t("providerForm.localProxyHeaderOverrides", {
              defaultValue: "Header 覆盖",
            })}
          </FormLabel>
          <Textarea
            value={headersJson}
            onChange={(event) => onHeadersJsonChange(event.target.value)}
            placeholder={'{\n  "X-Provider": "cc-switch"\n}'}
            className="min-h-[132px] resize-y font-mono text-xs"
            aria-invalid={Boolean(headerError)}
          />
          {headerError && (
            <p className="text-xs text-destructive">
              {t("providerForm.localProxyHeaderOverridesInvalidDetail", {
                error: headerError,
                defaultValue: "Header 覆盖格式错误：{{error}}",
              })}
            </p>
          )}
        </div>

        <div className="space-y-2">
          <FormLabel className="text-xs text-muted-foreground">
            {t("providerForm.localProxyBodyOverrides", {
              defaultValue: "Body 覆盖",
            })}
          </FormLabel>
          <Textarea
            value={bodyJson}
            onChange={(event) => onBodyJsonChange(event.target.value)}
            placeholder={'{\n  "temperature": 0.2\n}'}
            className="min-h-[132px] resize-y font-mono text-xs"
            aria-invalid={Boolean(bodyError)}
          />
          {bodyError && (
            <p className="text-xs text-destructive">
              {t("providerForm.localProxyBodyOverridesInvalidDetail", {
                error: bodyError,
                defaultValue: "Body 覆盖格式错误：{{error}}",
              })}
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
