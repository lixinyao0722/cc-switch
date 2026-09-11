import { useCallback } from "react";
import {
  skipToken,
  useIsMutating,
  useMutation,
  useQuery,
  useQueryClient,
  type MutateOptions,
  type QueryClient,
  type UseMutationOptions,
} from "@tanstack/react-query";
import { useTranslation } from "react-i18next";

const routingMutationKey = ["routing-operation"] as const;
const externalRoutingKey = ["routing-external-busy"] as const;
type ExternalRoutingState = Record<string, boolean>;
// React Query notifies components asynchronously. Reserve the operation before
// mutateAsync so two controls clicked in the same tick cannot both write.
const routingReservations = new WeakSet<QueryClient>();

export function setExternalRoutingBusy(
  queryClient: QueryClient,
  appType: string,
  busy: boolean,
) {
  queryClient.setQueryData<ExternalRoutingState>(
    externalRoutingKey,
    (previous = {}) => ({
      ...previous,
      [appType]: busy,
    }),
  );
}

function isExternalRoutingBusy(queryClient: QueryClient) {
  return Object.values(
    queryClient.getQueryData<ExternalRoutingState>(externalRoutingKey) ?? {},
  ).some(Boolean);
}

export function useRoutingBusy() {
  const pendingCount = useIsMutating({ mutationKey: routingMutationKey });
  const { data: externalBusy } = useQuery<ExternalRoutingState>({
    queryKey: externalRoutingKey,
    queryFn: skipToken,
    initialData: {},
    enabled: false,
    staleTime: Infinity,
    gcTime: Infinity,
  });
  return pendingCount > 0 || Object.values(externalBusy ?? {}).some(Boolean);
}

export function useRoutingMutation<TData, TVariables = void>(
  options: UseMutationOptions<TData, Error, TVariables>,
) {
  const queryClient = useQueryClient();
  const { t } = useTranslation();
  const mutation = useMutation({ ...options, mutationKey: routingMutationKey });
  const runMutation = mutation.mutateAsync;

  const mutateAsync = useCallback(
    (
      variables: TVariables,
      callbacks?: MutateOptions<TData, Error, TVariables>,
    ) => {
      if (
        routingReservations.has(queryClient) ||
        isExternalRoutingBusy(queryClient) ||
        queryClient.isMutating({ mutationKey: routingMutationKey }) > 0
      ) {
        return Promise.reject(
          new Error(
            t("proxy.routingBusy", {
              defaultValue: "路由操作正在进行，请稍候再试。",
            }),
          ),
        );
      }
      routingReservations.add(queryClient);
      return runMutation(variables, callbacks).finally(() => {
        routingReservations.delete(queryClient);
      });
    },
    [queryClient, runMutation, t],
  );

  const mutate = useCallback(
    (
      variables: TVariables,
      callbacks?: MutateOptions<TData, Error, TVariables>,
    ) => {
      void mutateAsync(variables, callbacks).catch(() => undefined);
    },
    [mutateAsync],
  );

  return { ...mutation, mutate, mutateAsync };
}
