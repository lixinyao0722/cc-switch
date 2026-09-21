import { describe, expect, it } from "vitest";
import { isModelHubModelCatalogEndpoint } from "@/lib/api/model-fetch";

describe("isModelHubModelCatalogEndpoint", () => {
  it("accepts ModelHub base and Responses URLs", () => {
    expect(
      isModelHubModelCatalogEndpoint(
        "https://aidp.bytedance.net/api/modelhub/online",
      ),
    ).toBe(true);
    expect(
      isModelHubModelCatalogEndpoint(
        "https://aidp.bytedance.net/api/modelhub/online/responses",
      ),
    ).toBe(true);
  });

  it("rejects invalid and lookalike URLs", () => {
    expect(isModelHubModelCatalogEndpoint("not-a-url")).toBe(false);
    expect(
      isModelHubModelCatalogEndpoint(
        "https://aidp.bytedance.net.example/api/modelhub/online",
      ),
    ).toBe(false);
    expect(
      isModelHubModelCatalogEndpoint(
        "https://aidp.bytedance.net/api/modelhub/online-preview",
      ),
    ).toBe(false);
  });
});
