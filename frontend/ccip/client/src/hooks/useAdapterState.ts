import { useQuery } from "@tanstack/react-query";
import { useMemo } from "react";
import {
  loadAdapterContext,
  readAdapterState,
  type AdapterContext,
  type AdapterState,
} from "@/lib/adapter/state";

export interface LoadedAdapter {
  address: string;
  hubChainId: number;
}

export function useAdapterState(loaded: LoadedAdapter | null) {
  const query = useQuery<{ ctx: AdapterContext; state: AdapterState }>({
    queryKey: ["adapter-state", loaded?.address, loaded?.hubChainId],
    enabled: !!loaded,
    staleTime: 15_000,
    retry: 0,
    queryFn: async () => {
      const ctx = await loadAdapterContext(loaded!.address, loaded!.hubChainId);
      const state = await readAdapterState(ctx);
      return { ctx, state };
    },
  });

  return useMemo(
    () => ({
      ctx: query.data?.ctx,
      state: query.data?.state,
      isLoading: query.isLoading,
      isFetching: query.isFetching,
      error: query.error as Error | undefined,
      refetch: query.refetch,
    }),
    [query.data, query.isLoading, query.isFetching, query.error, query.refetch],
  );
}
