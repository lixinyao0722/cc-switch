import { useTranslation } from "react-i18next";
import { FormLabel } from "@/components/ui/form";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import type {
  CodexActivitySummaryMode,
  CodexSessionHeaderAdapter,
  Retry429Config,
} from "@/types";
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
  codexMetadataModel?: string;
  codexActivitySummaryMode?: CodexActivitySummaryMode;
  rememberInvalidEncryptedReasoning?: boolean;
  onCodexSessionHeaderAdapterChange?: (
    value: CodexSessionHeaderAdapter | undefined,
  ) => void;
  onRetry429Change?: (value: Retry429Config | undefined) => void;
  onCodexMetadataModelChange?: (value: string | undefined) => void;
  onCodexActivitySummaryModeChange?: (
    value: CodexActivitySummaryMode | undefined,
  ) => void;
  onRememberInvalidEncryptedReasoningChange?: (
    value: boolean | undefined,
  ) => void;
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
  codexMetadataModel,
  codexActivitySummaryMode,
  rememberInvalidEncryptedReasoning,
  onCodexSessionHeaderAdapterChange,
  onRetry429Change,
  onCodexMetadataModelChange,
  onCodexActivitySummaryModeChange,
  onRememberInvalidEncryptedReasoningChange,
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
                if (!checked) {
                  onRetry429Change?.(undefined);
                  onCodexMetadataModelChange?.(undefined);
                  onCodexActivitySummaryModeChange?.(undefined);
                  onRememberInvalidEncryptedReasoningChange?.(undefined);
                }
              }}
            />
          </div>

          {codexSessionHeaderAdapter === "modelhub" && (
            <div className="space-y-3 border-t border-border-default pt-3">
              <div className="flex items-start justify-between gap-3">
                <div className="space-y-1">
                  <Label htmlFor="codex-metadata-mapping">
                    {t("providerForm.codexMetadataMapping", {
                      defaultValue: "Codex 内部元数据映射",
                    })}
                  </Label>
                  <p className="text-xs text-muted-foreground">
                    {t("providerForm.codexMetadataMappingHint", {
                      defaultValue:
                        "将已识别的标题、描述等内部 Luna 请求映射到指定模型。",
                    })}
                  </p>
                </div>
                <Switch
                  id="codex-metadata-mapping"
                  aria-label={t("providerForm.codexMetadataMapping", {
                    defaultValue: "Codex 内部元数据映射",
                  })}
                  checked={Boolean(codexMetadataModel?.trim())}
                  onCheckedChange={(checked) => {
                    onCodexMetadataModelChange?.(
                      checked
                        ? codexMetadataModel?.trim() || "gpt-5.6-sol"
                        : undefined,
                    );
                    if (!checked && codexActivitySummaryMode === "map") {
                      onCodexActivitySummaryModeChange?.("block");
                    }
                  }}
                />
              </div>

              {codexMetadataModel !== undefined && (
                <div className="space-y-1">
                  <Label htmlFor="codex-metadata-model">
                    {t("providerForm.codexMetadataModel", {
                      defaultValue: "元数据目标模型",
                    })}
                  </Label>
                  <Input
                    id="codex-metadata-model"
                    aria-label={t("providerForm.codexMetadataModel", {
                      defaultValue: "元数据目标模型",
                    })}
                    value={codexMetadataModel}
                    onChange={(event) =>
                      onCodexMetadataModelChange?.(event.target.value)
                    }
                  />
                </div>
              )}

              <div className="space-y-1">
                <Label htmlFor="codex-activity-summary-mode">
                  {t("providerForm.codexActivitySummaryMode", {
                    defaultValue: "活动摘要策略",
                  })}
                </Label>
                <select
                  id="codex-activity-summary-mode"
                  aria-label={t("providerForm.codexActivitySummaryMode", {
                    defaultValue: "活动摘要策略",
                  })}
                  className="flex h-9 w-full rounded-md border border-border-default bg-background px-3 py-2 text-sm shadow-sm focus:outline-none focus:border-border-active"
                  value={codexActivitySummaryMode ?? "passthrough"}
                  onChange={(event) => {
                    const mode = event.target.value as CodexActivitySummaryMode;
                    if (mode === "map" && !codexMetadataModel?.trim()) {
                      onCodexMetadataModelChange?.("gpt-5.6-sol");
                    }
                    onCodexActivitySummaryModeChange?.(mode);
                  }}
                >
                  <option value="passthrough">
                    {t("providerForm.codexActivitySummaryPassthrough", {
                      defaultValue: "原样发送 Luna",
                    })}
                  </option>
                  <option value="block">
                    {t("providerForm.codexActivitySummaryBlock", {
                      defaultValue: "本地拦截",
                    })}
                  </option>
                  <option value="map">
                    {t("providerForm.codexActivitySummaryMap", {
                      defaultValue: "映射到元数据模型",
                    })}
                  </option>
                </select>
              </div>

              <div className="flex items-start justify-between gap-3">
                <div className="space-y-1">
                  <Label htmlFor="remember-invalid-encrypted-reasoning">
                    {t("providerForm.rememberInvalidEncryptedReasoning", {
                      defaultValue: "记忆加密推理不兼容会话",
                    })}
                  </Label>
                  <p className="text-xs text-muted-foreground">
                    {t("providerForm.rememberInvalidEncryptedReasoningHint", {
                      defaultValue:
                        "首次确认上游无法验证历史加密推理后，同会话后续请求提前清理。",
                    })}
                  </p>
                </div>
                <Switch
                  id="remember-invalid-encrypted-reasoning"
                  aria-label={t(
                    "providerForm.rememberInvalidEncryptedReasoning",
                    { defaultValue: "记忆加密推理不兼容会话" },
                  )}
                  checked={rememberInvalidEncryptedReasoning === true}
                  onCheckedChange={(checked) =>
                    onRememberInvalidEncryptedReasoningChange?.(checked)
                  }
                />
              </div>

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
