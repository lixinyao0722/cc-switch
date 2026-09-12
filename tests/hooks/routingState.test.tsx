import type { ReactNode } from "react";
import {
  act,
  fireEvent,
  render,
  renderHook,
  screen,
  waitFor,
} from "@testing-library/react";
import { QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useProviderActions } from "@/hooks/useProviderActions";
import { useProxyStatus } from "@/hooks/useProxyStatus";
import { useUpdateProviderMutation } from "@/lib/query/mutations";
import { useProvidersQuery } from "@/lib/query/queries";
import { useAppProxyConfig } from "@/lib/query/proxy";
import { ProxyToggle } from "@/components/proxy/ProxyToggle";
import { ProviderList } from "@/components/providers/ProviderList";
import { UpdateProvider } from "@/contexts/UpdateContext";
import type { Provider } from "@/types";
import type {
  AppProxyConfig,
  ProxyStatus,
  ProxyTakeoverStatus,
} from "@/types/proxy";
import { createTestQueryClient } from "../utils/testQueryClient";
import { emitTauriEvent } from "../msw/tauriMocks";

const invokeMock = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() },
}));
vi.mock("@/lib/updater", () => ({
  checkForUpdate: async () => ({ status: "up-to-date" }),
}));
vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: () => ({
    isMaximized: async () => false,
    onResized: async () => () => {},
  }),
}));

const target: Provider = {
  id: "bytedance-modelhub-official-cli",
  name: "ModelHub",
  category: "third_party",
  settingsConfig: {},
  meta: {
    localProxyRequestOverrides: {
      codexSessionHeaderAdapter: "modelhub",
      codexRemoteSessions: true,
    },
  },
};

let currentId: string;
let status: ProxyStatus;
let takeover: ProxyTakeoverStatus;
let config: AppProxyConfig;
let switchRoute: () => Promise<unknown>;
let takeOverRoute: () => Promise<unknown>;
let updateRoute: () => Promise<unknown>;
let serverRoute: () => Promise<unknown>;
let writes: string[];

function converge() {
  currentId = target.id;
  status = { ...status, running: true, port: 17890 };
  takeover = { ...takeover, codex: true };
  config = { ...config, enabled: true };
}

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function setup() {
  const queryClient = createTestQueryClient();
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
  return { queryClient, wrapper };
}

function useRouteScreen() {
  return {
    actions: useProviderActions("codex", true, true),
    proxy: useProxyStatus(),
    providers: useProvidersQuery("codex"),
    config: useAppProxyConfig("codex"),
    update: useUpdateProviderMutation("codex"),
  };
}

beforeEach(() => {
  currentId = "official";
  status = {
    running: false,
    address: "127.0.0.1",
    port: 15721,
    active_connections: 0,
    total_requests: 0,
    success_requests: 0,
    failed_requests: 0,
    success_rate: 0,
    uptime_seconds: 0,
    current_provider: null,
    current_provider_id: null,
    last_request_at: null,
    last_error: null,
    failover_count: 0,
  };
  takeover = {
    claude: false,
    codex: false,
    gemini: false,
    grokbuild: false,
    opencode: false,
    openclaw: false,
    hermes: false,
  };
  config = {
    appType: "codex",
    enabled: false,
    autoFailoverEnabled: false,
    maxRetries: 3,
    streamingFirstByteTimeout: 60,
    streamingIdleTimeout: 120,
    nonStreamingTimeout: 600,
    circuitFailureThreshold: 4,
    circuitSuccessThreshold: 2,
    circuitTimeoutSeconds: 30,
    circuitErrorRateThreshold: 0.5,
    circuitMinRequests: 10,
  };
  writes = [];
  switchRoute = async () => {
    converge();
    return { warnings: [], codexRestartRequired: true };
  };
  takeOverRoute = async () => {
    converge();
  };
  updateRoute = async () => {
    converge();
    return true;
  };
  serverRoute = async () => ({ address: "127.0.0.1", port: 15721 });
  invokeMock.mockReset().mockImplementation((command: string) => {
    switch (command) {
      case "get_proxy_status":
        return Promise.resolve({ ...status });
      case "get_proxy_takeover_status":
        return Promise.resolve({ ...takeover });
      case "get_proxy_config_for_app":
        return Promise.resolve({ ...config });
      case "get_providers":
        return Promise.resolve({ [target.id]: target });
      case "get_current_provider":
        return Promise.resolve(currentId);
      case "switch_provider":
        writes.push(command);
        return switchRoute();
      case "set_proxy_takeover_for_app":
        writes.push(command);
        return takeOverRoute();
      case "update_provider":
        writes.push(command);
        return updateRoute();
      case "start_proxy_server":
      case "stop_proxy_server":
        writes.push(command);
        return serverRoute();
      case "get_failover_queue":
        return Promise.resolve([]);
      case "check_env_conflicts":
        return Promise.resolve([]);
      case "get_provider_health":
        return Promise.resolve(null);
      case "get_auto_failover_enabled":
        return Promise.resolve(false);
      default:
        return Promise.resolve(null);
    }
  });
});

describe("routed provider state", () => {
  it("shares tray busy state across controls and blocks writes until the completion event", async () => {
    localStorage.setItem("cc-switch-last-app", "codex");
    localStorage.removeItem("cc-switch-last-view");
    const { default: App } = await import("@/App");
    const { wrapper } = setup();
    const { result } = renderHook(useRouteScreen, { wrapper });
    render(
      <UpdateProvider>
        <App />
      </UpdateProvider>,
      { wrapper },
    );
    await waitFor(() =>
      expect(result.current.providers.data?.currentProviderId).toBe("official"),
    );
    act(() =>
      emitTauriEvent("route-operation-state", { appType: "codex", busy: true }),
    );
    await waitFor(() => {
      expect(result.current.proxy.isPending).toBe(true);
      expect(result.current.actions.isLoading).toBe(true);
      expect(
        screen.getByRole("button", { name: "provider.enable" }),
      ).toBeDisabled();
    });
    await act(async () => {
      await result.current.actions.switchProvider(target);
      await expect(
        result.current.proxy.setTakeoverForApp({
          appType: "codex",
          enabled: true,
        }),
      ).rejects.toThrow();
    });
    expect(writes).toEqual([]);
    act(() => {
      converge();
      emitTauriEvent("route-operation-state", {
        appType: "codex",
        busy: false,
      });
      emitTauriEvent("route-state-changed", { appType: "codex" });
    });
    await waitFor(() => {
      expect(result.current.proxy.isPending).toBe(false);
      expect(result.current.actions.isLoading).toBe(false);
      expect(result.current.providers.data?.currentProviderId).toBe(target.id);
      expect(result.current.proxy.status?.port).toBe(17890);
    });
    await act(async () => {
      await result.current.actions.switchProvider(target);
    });
    expect(writes).toEqual(["switch_provider"]);
  });

  it.each(["start", "stop"])(
    "rereads route state when server %s partially changes state then fails",
    async (operation) => {
      serverRoute = async () => {
        converge();
        throw new Error("server transaction failed");
      };
      const { wrapper } = setup();
      const { result } = renderHook(useRouteScreen, { wrapper });
      await waitFor(() =>
        expect(result.current.proxy.status?.running).toBe(false),
      );
      await act(async () => {
        const promise =
          operation === "start"
            ? result.current.proxy.startProxyServer()
            : result.current.proxy.stopProxyServer();
        await expect(promise).rejects.toThrow("server transaction failed");
      });
      await waitFor(() => {
        expect(result.current.proxy.status?.port).toBe(17890);
        expect(result.current.proxy.takeoverStatus?.codex).toBe(true);
        expect(result.current.providers.data?.currentProviderId).toBe(
          target.id,
        );
        expect(result.current.config.data?.enabled).toBe(true);
      });
    },
  );

  it.each(["provider-switched", "route-state-changed"])(
    "rereads route state on the %s desktop event",
    async (eventName) => {
      localStorage.setItem("cc-switch-last-app", "codex");
      localStorage.removeItem("cc-switch-last-view");
      const { default: App } = await import("@/App");
      const { wrapper } = setup();
      const { result } = renderHook(useRouteScreen, { wrapper });
      render(
        <UpdateProvider>
          <App />
        </UpdateProvider>,
        { wrapper },
      );
      await waitFor(() =>
        expect(result.current.providers.data?.currentProviderId).toBe(
          "official",
        ),
      );
      act(() => {
        converge();
        emitTauriEvent(eventName, { appType: "codex", providerId: target.id });
      });
      await waitFor(() => {
        expect(result.current.providers.data?.currentProviderId).toBe(
          target.id,
        );
        expect(result.current.proxy.status?.port).toBe(17890);
        expect(result.current.proxy.takeoverStatus?.codex).toBe(true);
        expect(result.current.config.data?.enabled).toBe(true);
      });
    },
  );

  it.each(["success", "rollback failure"])(
    "rereads every route query after switch %s",
    async (outcome) => {
      if (outcome === "rollback failure")
        switchRoute = async () => {
          converge();
          throw new Error("rollback incomplete");
        };
      const { wrapper } = setup();
      const { result } = renderHook(useRouteScreen, { wrapper });
      await waitFor(() =>
        expect(result.current.config.data?.enabled).toBe(false),
      );
      await act(async () => {
        await result.current.actions.switchProvider(target);
      });
      await waitFor(() => {
        expect(result.current.providers.data?.currentProviderId).toBe(
          target.id,
        );
        expect(result.current.proxy.status?.port).toBe(17890);
        expect(result.current.proxy.takeoverStatus?.codex).toBe(true);
        expect(result.current.config.data?.enabled).toBe(true);
      });
    },
  );

  it.each(["takeover", "provider edit"])(
    "rereads actual route state after failed %s",
    async (operation) => {
      const fail = async () => {
        converge();
        throw new Error("rollback incomplete");
      };
      takeOverRoute = fail;
      updateRoute = fail;
      const { wrapper } = setup();
      const { result } = renderHook(useRouteScreen, { wrapper });
      await waitFor(() =>
        expect(result.current.providers.data?.currentProviderId).toBe(
          "official",
        ),
      );
      await act(async () => {
        const promise =
          operation === "takeover"
            ? result.current.proxy.setTakeoverForApp({
                appType: "codex",
                enabled: true,
              })
            : result.current.update.mutateAsync({ provider: target });
        await expect(promise).rejects.toThrow("rollback incomplete");
      });
      await waitFor(() => {
        expect(result.current.providers.data?.currentProviderId).toBe(
          target.id,
        );
        expect(result.current.proxy.status?.port).toBe(17890);
        expect(result.current.proxy.takeoverStatus?.codex).toBe(true);
        expect(result.current.config.data?.enabled).toBe(true);
      });
    },
  );

  it.each(["switch", "takeover", "edit"])(
    "shares busy state while %s is pending",
    async (operation) => {
      const pending = deferred();
      switchRoute = async () => {
        await pending.promise;
        return { warnings: [] };
      };
      takeOverRoute = () => pending.promise;
      updateRoute = () => pending.promise;
      const { wrapper } = setup();
      const { result } = renderHook(useRouteScreen, { wrapper });
      await waitFor(() =>
        expect(result.current.proxy.isInitialStatusPending).toBe(false),
      );
      let done!: Promise<unknown>;
      act(() => {
        done =
          operation === "switch"
            ? result.current.actions.switchProvider(target)
            : operation === "takeover"
              ? result.current.proxy.setTakeoverForApp({
                  appType: "codex",
                  enabled: true,
                })
              : result.current.update.mutateAsync({ provider: target });
      });
      await waitFor(() => {
        expect(result.current.proxy.isPending).toBe(true);
        expect(result.current.actions.isLoading).toBe(true);
      });
      await act(async () => {
        pending.resolve();
        await done;
      });
      await waitFor(() => {
        expect(result.current.proxy.isPending).toBe(false);
        expect(result.current.actions.isLoading).toBe(false);
      });
    },
  );

  it("admits only one switch or takeover in the same tick", async () => {
    const pending = deferred();
    switchRoute = async () => {
      await pending.promise;
      return { warnings: [] };
    };
    const { wrapper } = setup();
    const { result } = renderHook(useRouteScreen, { wrapper });
    let first!: Promise<unknown>;
    let second!: Promise<unknown>;
    let takeoverAttempt!: Promise<unknown>;
    act(() => {
      first = result.current.actions.switchProvider(target);
      second = result.current.actions.switchProvider(target);
      takeoverAttempt = result.current.proxy
        .setTakeoverForApp({ appType: "codex", enabled: true })
        .catch(() => undefined);
    });
    await waitFor(() => expect(writes.length).toBeGreaterThan(0));
    expect(writes).toEqual(["switch_provider"]);
    await act(async () => {
      pending.resolve();
      await Promise.all([first, second, takeoverAttempt]);
    });
  });

  it("blocks switching behind a takeover and releases the gate after failure", async () => {
    const pending = deferred();
    takeOverRoute = async () => {
      await pending.promise;
      throw new Error("admin authorization cancelled");
    };
    const { wrapper } = setup();
    const { result } = renderHook(useRouteScreen, { wrapper });
    let takeoverAttempt!: Promise<unknown>;
    let switchAttempt!: Promise<unknown>;
    act(() => {
      takeoverAttempt = result.current.proxy
        .setTakeoverForApp({ appType: "codex", enabled: true })
        .catch(() => undefined);
      switchAttempt = result.current.actions.switchProvider(target);
    });
    await waitFor(() => expect(writes.length).toBeGreaterThan(0));
    expect(writes).toEqual(["set_proxy_takeover_for_app"]);
    await act(async () => {
      pending.resolve();
      await Promise.all([takeoverAttempt, switchAttempt]);
    });
    await waitFor(() => expect(result.current.proxy.isPending).toBe(false));
    await act(async () => {
      await result.current.actions.switchProvider(target);
    });
    expect(writes).toEqual(["set_proxy_takeover_for_app", "switch_provider"]);
    await waitFor(() =>
      expect(result.current.providers.data?.currentProviderId).toBe(target.id),
    );
  });

  it.each(["switch", "takeover"])(
    "disables real provider controls and the top toggle during %s",
    async (operation) => {
      const pending = deferred();
      switchRoute = async () => {
        await pending.promise;
        return { warnings: [] };
      };
      takeOverRoute = () => pending.promise;
      const { wrapper } = setup();
      function Screen() {
        const { switchProvider } = useProviderActions("codex", false, false);
        return (
          <>
            <ProxyToggle activeApp="codex" />
            <ProviderList
              providers={{ [target.id]: target }}
              currentProviderId="official"
              appId="codex"
              onSwitch={switchProvider}
              onEdit={() => {}}
              onDelete={() => {}}
              onDuplicate={() => {}}
              onOpenWebsite={() => {}}
            />
          </>
        );
      }
      render(<Screen />, { wrapper });
      const toggle = screen.getByRole("switch");
      const switchButton = screen.getByRole("button", {
        name: "provider.enable",
      });
      await waitFor(() => expect(toggle).toBeEnabled());
      fireEvent.click(operation === "switch" ? switchButton : toggle);
      await waitFor(() => {
        expect(toggle).toBeDisabled();
        expect(switchButton).toBeDisabled();
      });
      await act(async () => {
        pending.resolve();
      });
      await waitFor(() => expect(toggle).toBeEnabled());
    },
  );
});
