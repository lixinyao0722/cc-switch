import {
  useQuery,
  useMutation,
  useQueryClient,
  type QueryClient,
} from "@tanstack/react-query";
import { proxyApi } from "@/lib/api/proxy";
import { toast } from "sonner";
import { useTranslation } from "react-i18next";
import { useRoutingMutation } from "./routing";
import type {
  GlobalProxyConfig,
  AppProxyConfig,
  ProxyTakeoverStatus,
} from "@/types/proxy";

export const proxyKeys = {
  status: ["proxyStatus"] as const,
  takeoverStatus: ["proxyTakeoverStatus"] as const,
  globalConfig: ["globalProxyConfig"] as const,
  appConfig: (appType: string) => ["appProxyConfig", appType] as const,
};

// Read all route state after a transaction, including failed or partial rollback.
// A restored provider id alone does not prove the listener/config was restored.
export async function invalidateRoutingState(
  queryClient: QueryClient,
  appType?: string,
) {
  await Promise.all([
    queryClient.invalidateQueries({
      queryKey: appType ? ["providers", appType] : ["providers"],
    }),
    queryClient.invalidateQueries({ queryKey: proxyKeys.status }),
    queryClient.invalidateQueries({ queryKey: proxyKeys.takeoverStatus }),
    queryClient.invalidateQueries({
      queryKey: appType ? proxyKeys.appConfig(appType) : ["appProxyConfig"],
    }),
    ...(!appType || appType === "claude-desktop"
      ? [queryClient.invalidateQueries({ queryKey: ["claudeDesktopStatus"] })]
      : []),
  ]);
}

// ========== 代理服务器状态 Hooks ==========

/**
 * 获取代理服务器状态
 */
export function useProxyStatusQuery() {
  return useQuery({
    queryKey: proxyKeys.status,
    queryFn: () => proxyApi.getProxyStatus(),
    // 仅在服务运行时轮询
    refetchInterval: (query) => (query.state.data?.running ? 2000 : false),
    // 保持之前的数据，避免闪烁
    placeholderData: (previousData) => previousData,
  });
}

/**
 * 获取各应用接管状态
 */
export function useProxyTakeoverStatus(poll = true) {
  return useQuery({
    queryKey: proxyKeys.takeoverStatus,
    queryFn: () => proxyApi.getProxyTakeoverStatus(),
    refetchInterval: poll ? 2000 : false,
    ...(poll
      ? {}
      : {
          placeholderData: (previousData: ProxyTakeoverStatus | undefined) =>
            previousData,
        }),
  });
}

// ========== 代理服务器控制 Hooks ==========

/**
 * 设置应用接管状态
 */
export function useSetProxyTakeoverForApp() {
  const queryClient = useQueryClient();

  return useRoutingMutation({
    mutationFn: ({ appType, enabled }: { appType: string; enabled: boolean }) =>
      proxyApi.setProxyTakeoverForApp(appType, enabled),
    onSettled: (_data, _error, variables) =>
      invalidateRoutingState(queryClient, variables.appType),
  });
}

// ========== v3+ 全局/应用级配置 Hooks ==========

/**
 * 获取全局代理配置
 */
export function useGlobalProxyConfig() {
  return useQuery({
    queryKey: proxyKeys.globalConfig,
    queryFn: () => proxyApi.getGlobalProxyConfig(),
  });
}

/**
 * 更新全局代理配置
 */
export function useUpdateGlobalProxyConfig() {
  const queryClient = useQueryClient();
  const { t } = useTranslation();

  return useMutation({
    mutationFn: (config: GlobalProxyConfig) =>
      proxyApi.updateGlobalProxyConfig(config),
    onSuccess: () => {
      toast.success(t("proxy.settings.toast.saved"), { closeButton: true });
      queryClient.invalidateQueries({ queryKey: proxyKeys.globalConfig });
      queryClient.invalidateQueries({ queryKey: proxyKeys.status });
    },
    onError: (error: Error) => {
      toast.error(
        t("proxy.settings.toast.saveFailed", { error: error.message }),
      );
    },
  });
}

/**
 * 获取指定应用的代理配置
 */
export function useAppProxyConfig(appType: string) {
  return useQuery({
    queryKey: proxyKeys.appConfig(appType),
    queryFn: () => proxyApi.getProxyConfigForApp(appType),
    enabled: !!appType,
  });
}

/**
 * 更新指定应用的代理配置
 */
export function useUpdateAppProxyConfig() {
  const queryClient = useQueryClient();
  const { t } = useTranslation();

  return useMutation({
    mutationFn: (config: AppProxyConfig) =>
      proxyApi.updateProxyConfigForApp(config),
    onSuccess: (_, variables) => {
      toast.success(t("proxy.settings.toast.saved"), { closeButton: true });
      queryClient.invalidateQueries({
        queryKey: proxyKeys.appConfig(variables.appType),
      });
      queryClient.invalidateQueries({
        queryKey: ["autoFailoverEnabled", variables.appType],
      });
      queryClient.invalidateQueries({ queryKey: ["circuitBreakerConfig"] });
      queryClient.invalidateQueries({ queryKey: proxyKeys.status });
    },
    onError: (error: Error) => {
      toast.error(
        t("proxy.settings.toast.saveFailed", { error: error.message }),
      );
    },
  });
}
