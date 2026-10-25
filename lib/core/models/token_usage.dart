class TokenUsage {
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;
  final int totalTokens;

  const TokenUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cachedTokens = 0,
    this.totalTokens = 0,
  });

  TokenUsage merge(TokenUsage other) {
    // Within one streaming round the usage snapshots are cumulative:
    // - prompt tokens: keep the latest non-zero value
    // - completion tokens: keep the latest non-zero value
    // - cached tokens: keep the latest non-zero value
    final prompt = other.promptTokens > 0 ? other.promptTokens : promptTokens;
    final completion = other.completionTokens > 0
        ? other.completionTokens
        : completionTokens;
    final cached = other.cachedTokens > 0 ? other.cachedTokens : cachedTokens;
    final splitTotal = prompt + completion;
    final explicitTotal = other.totalTokens > 0
        ? other.totalTokens
        : totalTokens;
    final total = splitTotal > 0 ? splitTotal : explicitTotal;
    return TokenUsage(
      promptTokens: prompt,
      completionTokens: completion,
      cachedTokens: cached,
      totalTokens: total,
    );
  }

  TokenUsage add(TokenUsage other) {
    final prompt = promptTokens + other.promptTokens;
    final completion = completionTokens + other.completionTokens;
    final cached = cachedTokens + other.cachedTokens;
    final splitTotal = prompt + completion;
    return TokenUsage(
      promptTokens: prompt,
      completionTokens: completion,
      cachedTokens: cached,
      totalTokens: splitTotal > 0
          ? splitTotal
          : totalTokens + other.totalTokens,
    );
  }
}
