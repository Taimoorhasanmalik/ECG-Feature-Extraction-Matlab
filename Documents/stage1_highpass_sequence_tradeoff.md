# Stage 1 High-Pass Sequence Tradeoff

The final low-power Stage 1 base model is the Q3.8 fixed-point high-pass Normal vs Abnormal classifier. It uses only four hardware-simple window features: `mean_abs`, `zero_crossings`, `line_length`, and `threshold_crossing_count`. The dropped features are `rms_amplitude` and `robust_range`. The base model is designed to be sensitive, meaning it should catch nearly all abnormal rhythm windows even if it produces extra false positives.

The base model alone achieved 91.93% accuracy, 0.5483 precision, 0.9734 recall, and 0.7015 F1 on the holdout set. This result shows the intended behavior: recall is very high, so abnormal windows are rarely missed, but precision is low because many normal windows are also flagged as abnormal. In a power-aware pipeline this is acceptable only if the next stage can reduce false positives or if a sequence rule is added before activating the high-power classifier.

Sequence detection improves the decision by checking temporal consistency across three consecutive windows. Instead of classifying a single window independently, the system counts how many of the last three windows were marked abnormal by the base model. This count is called `abnormal_vote_count`. A stricter rule requires more abnormal votes before the final output becomes Abnormal.

| Sequence Rule | Accuracy | Precision | Recall | F1 | Interpretation |
|---|---:|---:|---:|---:|---|
| At least 1 of 3 abnormal | 91.85% | 0.7634 | 0.9959 | 0.8643 | Most sensitive; catches almost everything but still allows more false positives. |
| At least 2 of 3 abnormal | 95.32% | 0.8596 | 0.9806 | 0.9161 | Best balanced setting; strong precision gain while recall remains very high. |
| All 3 of 3 abnormal | 96.68% | 0.9273 | 0.9470 | 0.9370 | Highest accuracy and precision; fewer false positives but more missed abnormal windows. |

The tradeoff is straightforward: increasing the required abnormal count improves precision because isolated false abnormal detections are suppressed. However, it can reduce recall because short abnormal episodes or boundary windows may not produce enough consecutive abnormal votes. The 1-of-3 rule is the safest for not missing abnormal activity, while the 3-of-3 rule is the strictest and minimizes unnecessary high-power activation.

For the thesis, the selected operating point is the 2-of-3 rule. This rule keeps recall very high at 0.9806 while improving precision to 0.8596. It misses 52 abnormal sequences on the holdout set, which is still low, but it cuts false positives almost in half compared with the 1-of-3 rule. This is the best practical balance because the low-power gate still passes nearly all abnormal activity to the high-power classifier while avoiding many unnecessary high-power activations.

The 1-of-3 rule can still be reported as the maximum-recall comparison point. It achieves recall of 0.9959 and misses only 11 abnormal sequences, but its precision is lower at 0.7634 because it allows more false positives. The 3-of-3 rule gives the highest precision, 0.9273, but recall drops to 0.9470 and missed abnormal sequences increase to 142. Since the design requirement is high recall with reasonable precision, 2-of-3 is the selected configuration.

In summary, the sequence rule turns the low-power detector from a highly sensitive but noisy base classifier into a more reliable abnormality gate. For this system, the chosen gate is the 2-of-3 rule because it maintains high abnormal recall while providing a large precision improvement over the base model. This supports the staged design: the low-power model runs continuously, the sequence count reduces unstable decisions, and the high-power arrhythmia classifier is activated when abnormality is present in most of the recent windows.
