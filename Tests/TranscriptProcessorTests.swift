import Foundation

enum TranscriptProcessorTests {
    static func run() {
        for response in ["EMPTY", "\"EMPTY\"", "\"\"", " \n "] {
            let result = TranscriptProcessor.resolveDictationResult(
                PostProcessingResult(
                    transcript: TranscriptOutputSanitizer.postProcessedTranscript(response),
                    prompt: "Synthetic cleanup prompt"
                ),
                rawTranscript: "  Please review the synthetic report. \n"
            )
            TestSupport.expectEqual(result.finalTranscript, "Please review the synthetic report.")
            TestSupport.expect(result.outcome.usedRawTranscriptFallback, "Empty cleanup must use raw fallback")
            TestSupport.expectEqual(result.prompt, "Synthetic cleanup prompt")
        }

        let result = TranscriptProcessor.resolveDictationResult(
            PostProcessingResult(transcript: "Clean synthetic report.", prompt: "Synthetic prompt"),
            rawTranscript: "Um clean synthetic report"
        )
        TestSupport.expectEqual(result.finalTranscript, "Clean synthetic report.")
        TestSupport.expectEqual(result.outcome.statusMessage(), "Post-processing succeeded")
    }
}
