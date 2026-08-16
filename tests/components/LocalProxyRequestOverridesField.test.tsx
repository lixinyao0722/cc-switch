import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { LocalProxyRequestOverridesField } from "@/components/providers/forms/LocalProxyRequestOverridesField";
import { Form } from "@/components/ui/form";
import { useForm } from "react-hook-form";
import type { ComponentProps } from "react";

vi.mock("react-i18next", () => ({
  useTranslation: () => ({ t: (key: string) => key }),
}));

const baseProps = {
  headersJson: "",
  bodyJson: '{ "max_output_tokens": 128000 }',
  onHeadersJsonChange: vi.fn(),
  onBodyJsonChange: vi.fn(),
};

function FieldWithForm(
  props: ComponentProps<typeof LocalProxyRequestOverridesField>,
) {
  const form = useForm();
  return (
    <Form {...form}>
      <LocalProxyRequestOverridesField {...props} />
    </Form>
  );
}

describe("LocalProxyRequestOverridesField", () => {
  it("reveals ModelHub retry controls after the Codex session adapter is enabled", () => {
    const onCodexSessionHeaderAdapterChange = vi.fn();
    const onRetry429Change = vi.fn();
    const { rerender } = render(
      <FieldWithForm
        {...baseProps}
        showModelHubControls
        onCodexSessionHeaderAdapterChange={onCodexSessionHeaderAdapterChange}
        onRetry429Change={onRetry429Change}
      />,
    );

    fireEvent.click(
      screen.getByRole("switch", {
        name: "providerForm.modelhubSessionHeaderAdapter",
      }),
    );
    expect(onCodexSessionHeaderAdapterChange).toHaveBeenCalledWith("modelhub");

    rerender(
      <FieldWithForm
        {...baseProps}
        showModelHubControls
        codexSessionHeaderAdapter="modelhub"
        onCodexSessionHeaderAdapterChange={onCodexSessionHeaderAdapterChange}
        onRetry429Change={onRetry429Change}
      />,
    );
    fireEvent.click(
      screen.getByRole("switch", {
        name: "providerForm.sameProviderRetry429",
      }),
    );
    expect(onRetry429Change).toHaveBeenCalledWith({
      maxRetries: 1,
      baseDelayMs: 2000,
      maxDelayMs: 30000,
      honorRetryAfter: true,
    });
  });

  it("updates the retry count without changing the other retry fields", () => {
    const onRetry429Change = vi.fn();
    render(
      <FieldWithForm
        {...baseProps}
        showModelHubControls
        codexSessionHeaderAdapter="modelhub"
        retry429={{
          maxRetries: 10,
          baseDelayMs: 1000,
          maxDelayMs: 30000,
          honorRetryAfter: true,
        }}
        onCodexSessionHeaderAdapterChange={vi.fn()}
        onRetry429Change={onRetry429Change}
      />,
    );

    fireEvent.change(screen.getByLabelText("providerForm.retry429MaxRetries"), {
      target: { value: "6" },
    });

    expect(onRetry429Change).toHaveBeenCalledWith({
      maxRetries: 6,
      baseDelayMs: 1000,
      maxDelayMs: 30000,
      honorRetryAfter: true,
    });
  });

  it("renders configurable metadata, activity-summary, and encrypted-reasoning policies", () => {
    render(
      <FieldWithForm
        {...baseProps}
        showModelHubControls
        codexSessionHeaderAdapter="modelhub"
        codexMetadataModel="gpt-5.6-sol"
        codexActivitySummaryMode="map"
        rememberInvalidEncryptedReasoning
        onCodexSessionHeaderAdapterChange={vi.fn()}
        onCodexMetadataModelChange={vi.fn()}
        onCodexActivitySummaryModeChange={vi.fn()}
        onRememberInvalidEncryptedReasoningChange={vi.fn()}
        onRetry429Change={vi.fn()}
      />,
    );

    expect(
      screen.getByRole("switch", {
        name: "providerForm.codexMetadataMapping",
      }),
    ).toBeChecked();
    expect(
      screen.getByLabelText("providerForm.codexMetadataModel"),
    ).toHaveValue("gpt-5.6-sol");
    expect(
      screen.getByLabelText("providerForm.codexActivitySummaryMode"),
    ).toHaveValue("map");
    expect(
      screen.getByRole("switch", {
        name: "providerForm.rememberInvalidEncryptedReasoning",
      }),
    ).toBeChecked();
  });

  it("clears every ModelHub policy when the session adapter is disabled", () => {
    const onCodexSessionHeaderAdapterChange = vi.fn();
    const onRetry429Change = vi.fn();
    const onCodexMetadataModelChange = vi.fn();
    const onCodexActivitySummaryModeChange = vi.fn();
    const onRememberInvalidEncryptedReasoningChange = vi.fn();
    render(
      <FieldWithForm
        {...baseProps}
        showModelHubControls
        codexSessionHeaderAdapter="modelhub"
        retry429={{
          maxRetries: 3,
          baseDelayMs: 1000,
          maxDelayMs: 30000,
          honorRetryAfter: true,
        }}
        codexMetadataModel="gpt-5.6-sol"
        codexActivitySummaryMode="block"
        rememberInvalidEncryptedReasoning
        onCodexSessionHeaderAdapterChange={onCodexSessionHeaderAdapterChange}
        onRetry429Change={onRetry429Change}
        onCodexMetadataModelChange={onCodexMetadataModelChange}
        onCodexActivitySummaryModeChange={onCodexActivitySummaryModeChange}
        onRememberInvalidEncryptedReasoningChange={
          onRememberInvalidEncryptedReasoningChange
        }
      />,
    );

    fireEvent.click(
      screen.getByRole("switch", {
        name: "providerForm.modelhubSessionHeaderAdapter",
      }),
    );

    expect(onCodexSessionHeaderAdapterChange).toHaveBeenCalledWith(undefined);
    expect(onRetry429Change).toHaveBeenCalledWith(undefined);
    expect(onCodexMetadataModelChange).toHaveBeenCalledWith(undefined);
    expect(onCodexActivitySummaryModeChange).toHaveBeenCalledWith(undefined);
    expect(onRememberInvalidEncryptedReasoningChange).toHaveBeenCalledWith(
      undefined,
    );
  });
});
